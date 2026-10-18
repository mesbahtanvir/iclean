import CleanupKit
import Foundation
import Observation

/// App state: access, scanning, results, selection and removal.
@Observable @MainActor
final class AppModel {
    let environment: AppEnvironment

    var access: LibraryAccess
    var progress: ScanProgress?
    var isScanning = false
    var hasInterruptedScan = false
    var lastScanDate: Date?
    var results: CleanupResults = .empty
    var selection: Set<String> = []
    var lastSummary: CleanupSummary?
    var errorMessage: String?
    /// Keeps a scan going after the user leaves the app (002).
    let continuation = ScanContinuation()
    /// True while results are being built, so the screen does not claim "clean" meanwhile.
    var isBuildingResults = false
    /// Tells a finished build whether it is still the newest one.
    private var resultsGeneration = 0

    private var changesTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.access = environment.library.authorizationStatus()
        continuation.onAutoResume = { [weak self] in self?.resumeScan() }
    }

    // MARK: Lifecycle

    func onLaunch() async {
        if let session = try? await environment.store.currentSession() {
            hasInterruptedScan = session.isActive
            lastScanDate = session.finishedAt
        }
        await reloadResults()
        observeLibraryChanges()
    }

    /// Quick check for new or changed photos each time the app opens (FR-005a).
    func onForeground() async {
        continuation.appWillEnterForeground()
        access = environment.library.authorizationStatus()
        // A scan paused only because background time ran out resumes by itself: the
        // continuation decides from the paused event (002 FR-009).
        guard access == .full || access == .limited, !isScanning, !hasInterruptedScan,
            lastScanDate != nil
        else { return }
        _ = await environment.scanner.quickCheck()
        await reloadResults()
    }

    func requestAccess() async {
        access = await environment.library.requestAuthorization()
        observeLibraryChanges()
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        hasInterruptedScan = false
        continuation.scanStarted(scanner: environment.scanner)
        Task {
            for await p in await environment.scanner.startFullScan() {
                progress = p
                continuation.update(p)
            }
            isScanning = false
            continuation.scanEnded()
            if progress?.state == .completed { lastScanDate = .now }
            await reloadResults()
        }
    }

    func pauseScan() {
        continuation.scanPausedByUser()
        Task { await environment.scanner.pause(reason: .user) }
    }

    func resumeScan() {
        Task { await environment.scanner.resume() }
        continuation.scanResumedByUser()
    }

    func stopScan() { Task { await environment.scanner.stop() } }

    func onBackground() { continuation.appDidEnterBackground() }

    // MARK: Results

    func reloadResults() async {
        resultsGeneration += 1
        let generation = resultsGeneration
        isBuildingResults = true
        let items = (try? await environment.store.items()) ?? []
        let keepMarks = (try? await environment.store.keepMarks()) ?? []
        // Grouping is CPU-heavy for a real library. It must not run on the main thread:
        // iOS ends an app whose launch does not reach the screen within 10 seconds, and
        // this did exactly that on a phone with a scanned library.
        let builder = environment.resultsBuilder
        let built = await Task.detached(priority: .userInitiated) {
            builder.buildResults(items: items, keepMarks: keepMarks)
        }.value
        // A newer build, or a change made to the results meanwhile, makes this one stale.
        guard generation == resultsGeneration else { return }
        isBuildingResults = false
        apply(built)
        Task { await measureSizes() }
    }

    /// Results were changed in place: a build that is still running would bring back
    /// what was just removed, so it is discarded.
    private func invalidateBuild() {
        resultsGeneration += 1
        isBuildingResults = false
    }

    private func apply(_ new: CleanupResults) {
        results = new
        selection = new.defaultSelection
    }

    /// Replaces size estimates with real sizes for items shown in results.
    private func measureSizes() async {
        let shown = results.categories.flatMap(\.allMembers).compactMap { results.items[$0] }
        let updated = await environment.sizeMeasurer.measure(shown)
        for item in updated { results.items[item.assetID] = item }
    }

    private func observeLibraryChanges() {
        guard changesTask == nil, access == .full || access == .limited else { return }
        let stream = environment.library.changes()
        changesTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                // Items deleted or changed elsewhere are dropped from results.
                let gone = change.removed.union(change.insertedOrChanged)
                self.invalidateBuild()
                self.results = self.results.removing(gone)
                self.selection.subtract(gone)
            }
        }
    }

    // MARK: Selection

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func setSelected(_ ids: [String], _ selected: Bool) {
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
    }

    func selectedCount(in category: CleanupCategory) -> Int {
        results.category(category)?.allMembers.filter(selection.contains).count ?? 0
    }

    /// Makes `id` the keeper of its group; the previous keeper becomes removable
    /// (Story 1 scenario 2). Favorites always stay keepers.
    func makeKeeper(_ id: String) {
        for ci in results.categories.indices {
            for gi in results.categories[ci].groups.indices
            where results.categories[ci].groups[gi].members.contains(id) {
                var group = results.categories[ci].groups[gi]
                let protected = group.keepers.filter {
                    results.items[$0]?.metadata.isFavorite == true
                }
                let demoted = group.keepers.subtracting(protected).subtracting([id])
                group.keepers = protected.union([id])
                results.categories[ci].groups[gi] = group
                selection.remove(id)
                selection.formUnion(demoted)
                return
            }
        }
    }

    /// Never flag this item again (FR-011).
    func alwaysKeep(_ id: String) async {
        try? await environment.store.setKeep(id, true)
        invalidateBuild()
        results = results.removing([id])
        selection.remove(id)
    }

    // MARK: Removal

    /// The selected items in one category, or everywhere when `category` is nil.
    func selection(in category: CleanupCategory?) -> Set<String> {
        guard let category else { return selection }
        return selection.intersection(results.category(category)?.allMembers ?? [])
    }

    func removalPreview(category: CleanupCategory?) -> RemovalPreview {
        environment.remover.summary(for: selection(in: category), in: results)
    }

    func removeSelected(category: CleanupCategory?, confirmRemoveAll: Bool) async -> CleanupSummary?
    {
        do {
            let summary = try await environment.remover.remove(
                selection(in: category), in: results, confirmRemoveAll: confirmRemoveAll)
            if !summary.cancelled {
                let removed = Set(summary.removedAssetIDs)
                try? await environment.store.deleteItems(removed)
                invalidateBuild()
                results = results.removing(removed)
                selection.subtract(removed)
                Log.removal.info("Removed \(summary.removedCount) items")
            }
            lastSummary = summary
            return summary
        } catch {
            errorMessage = String(localized: "Nothing was removed.")
            return nil
        }
    }

    // MARK: Settings

    /// Recent scans and how they ended (003 FR-012).
    func recentSessions() async -> [ScanSession] {
        (try? await environment.store.sessions()) ?? []
    }

    func clearKeepMarks() async {
        try? await environment.store.clearKeepMarks()
        await reloadResults()
    }

    func deleteAllData() async {
        // A running scan would re-create its session and chunks right after the delete.
        if isScanning { await environment.scanner.stop() }
        try? await environment.store.deleteAllData()
        lastScanDate = nil
        hasInterruptedScan = false
        progress = nil
        apply(.empty)
    }
}
