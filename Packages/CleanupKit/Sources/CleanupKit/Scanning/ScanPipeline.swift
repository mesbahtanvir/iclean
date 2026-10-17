import CoreGraphics
import Foundation

public protocol Scanner: Sendable {
    /// Full scan: analyzes every item that is new or changed since it was last analyzed.
    /// Continues an interrupted session if one exists.
    func startFullScan() async -> AsyncStream<ScanProgress>
    /// Quick check for new or changed items, run on app open (FR-005a).
    func quickCheck() async -> ScanProgress
    func pause() async
    func resume() async
    func stop() async
}

/// Scans the library in the foreground, saving progress so it can resume
/// (FR-005, FR-006, research R10, R11).
public actor ScanPipeline: Scanner {
    public static let previewSize = 512

    private let library: PhotoLibrary
    private let store: Store
    private let analyzer: Analyzer
    private let concurrency: Int
    private let saveEvery: Int
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState

    private var task: Task<Void, Never>?
    private var isPaused = false
    private var stopRequested = false
    private var session: ScanSession?

    public init(
        library: PhotoLibrary, store: Store, analyzer: Analyzer = DefaultAnalyzer(),
        concurrency: Int = 4, saveEvery: Int = 100,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        }
    ) {
        self.library = library
        self.store = store
        self.analyzer = analyzer
        self.concurrency = max(1, concurrency)
        self.saveEvery = max(1, saveEvery)
        self.thermalState = thermalState
    }

    // MARK: Scanner

    public func startFullScan() async -> AsyncStream<ScanProgress> {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
        guard task == nil else {
            continuation.finish()
            return stream
        }
        isPaused = false
        stopRequested = false
        task = Task { [weak self] in
            _ = await self?.run(kind: .full) { continuation.yield($0) }
            continuation.finish()
            await self?.clearTask()
        }
        return stream
    }

    public func quickCheck() async -> ScanProgress {
        guard task == nil else { return snapshot() }
        isPaused = false
        stopRequested = false
        let work = Task { await self.run(kind: .quickCheck) { _ in } }
        task = Task { _ = await work.value }
        let result = await work.value
        task = nil
        return result
    }

    public func pause() async {
        guard task != nil else { return }
        isPaused = true
        if var s = session {
            s.state = .paused
            session = s
            try? await store.saveSession(s)
        }
    }

    public func resume() async {
        isPaused = false
        if var s = session, s.state == .paused {
            s.state = .running
            session = s
            try? await store.saveSession(s)
        }
    }

    public func stop() async {
        stopRequested = true
        isPaused = false
        await task?.value
    }

    private func clearTask() { task = nil }

    // MARK: Run

    @discardableResult
    private func run(kind: ScanKind, progress: @Sendable (ScanProgress) -> Void) async -> ScanProgress {
        let metadata = await library.fetchAllItems()
        let stored = (try? await store.items()) ?? []
        let storedByID = Dictionary(stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(metadata.map(\.assetID))

        // Forget items that are no longer in the library.
        try? await store.deleteItems(Set(storedByID.keys).subtracting(currentIDs))

        // Refresh metadata that can change without re-analysis (favorites, albums).
        var refreshed: [LibraryItem] = []
        var toAnalyze: [AssetMetadata] = []
        for m in metadata {
            if let existing = storedByID[m.assetID], existing.metadata.modificationDate == m.modificationDate {
                if existing.metadata != m {
                    var updated = existing
                    updated.metadata = m
                    refreshed.append(updated)
                }
            } else {
                toAnalyze.append(m)
            }
        }
        try? await store.upsert(refreshed)

        // Continue an interrupted session, or start a new one.
        var s: ScanSession
        if let previous = try? await store.currentSession(), previous.isActive {
            s = previous
            s.kind = kind == .full ? .full : previous.kind
            s.state = .running
            s.totalItems = previous.processedItems + toAnalyze.count
        } else {
            s = ScanSession(kind: kind, state: .running, totalItems: toAnalyze.count)
        }
        session = s
        try? await store.saveSession(s)
        progress(snapshot())

        var pending: [LibraryItem] = []
        var index = 0
        await withTaskGroup(of: LibraryItem?.self) { group in
            func addNext() -> Bool {
                guard index < toAnalyze.count else { return false }
                let m = toAnalyze[index]
                index += 1
                group.addTask(priority: .userInitiated) { [library, analyzer] in
                    await Self.analyze(m, library: library, analyzer: analyzer)
                }
                return true
            }
            for _ in 0..<concurrency where !addNext() { break }

            while let result = await group.next() {
                if let item = result {
                    pending.append(item)
                    session?.processedItems += 1
                    if item.analysisSource == .notScanned { session?.notScannedCount += 1 }
                    session?.lastProcessedAssetID = item.assetID
                }
                if pending.count >= saveEvery {
                    await flush(&pending)
                    progress(snapshot())
                }
                if stopRequested {
                    group.cancelAll()
                    continue
                }
                await waitWhilePaused(progress: progress)
                if stopRequested {
                    group.cancelAll()
                    continue
                }
                _ = addNext()
            }
        }
        await flush(&pending)

        if var final = session {
            final.state = stopRequested ? .stopped : .completed
            final.finishedAt = .now
            session = final
            try? await store.saveSession(final)
        }
        let final = snapshot()
        progress(final)
        session = nil
        return final
    }

    private func waitWhilePaused(progress: @Sendable (ScanProgress) -> Void) async {
        var reported = false
        while !stopRequested, isPaused || isTooHot {
            if !reported {
                progress(snapshot())
                reported = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if reported { progress(snapshot()) }
    }

    private var isTooHot: Bool {
        let state = thermalState()
        return state == .serious || state == .critical
    }

    private func flush(_ pending: inout [LibraryItem]) async {
        guard !pending.isEmpty else { return }
        try? await store.upsert(pending)
        pending.removeAll(keepingCapacity: true)
        if let s = session { try? await store.saveSession(s) }
    }

    private func snapshot() -> ScanProgress {
        guard let s = session else {
            return ScanProgress(processed: 0, total: 0, notScanned: 0, state: .idle)
        }
        return ScanProgress(
            processed: s.processedItems, total: s.totalItems, notScanned: s.notScannedCount,
            state: isPaused ? .paused : s.state, isThermalPaused: !isPaused && isTooHot)
    }

    static func analyze(
        _ m: AssetMetadata, library: PhotoLibrary, analyzer: Analyzer
    ) async -> LibraryItem? {
        guard !Task.isCancelled else { return nil }
        let preview = await library.preview(for: m.assetID, maxPixels: previewSize)
        guard let image = preview.image else {
            return LibraryItem(metadata: m, analysisSource: .notScanned, analysis: nil)
        }
        guard let analysis = try? await analyzer.analyze(image, metadata: m) else {
            return LibraryItem(metadata: m, analysisSource: .notScanned, analysis: nil)
        }
        return LibraryItem(metadata: m, analysisSource: preview.source, analysis: analysis)
    }
}
