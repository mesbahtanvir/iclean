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
    let continuation: any ScanKeepAlive = makePlatformScanKeepAlive()
    /// True while results are being built, so the screen does not claim "clean" meanwhile.
    var isBuildingResults = false
    /// Tells a finished build whether it is still the newest one.
    private var resultsGeneration = 0
    /// Results found while the person was reviewing. They are shown when they return to Home or
    /// ask for them, never under a list they have open (004 FR-010).
    private(set) var pendingResults: CleanupResults?
    /// How many items `pendingResults` would add to the screen.
    private(set) var pendingNewCount = 0
    /// False while a category or group is open. Set by `HomeView`.
    private(set) var isOnHome = true
    /// What the person decided, laid over every rebuild so an update never undoes it (004 FR-011).
    private var choices = ReviewChoices()
    private var publishedRevision = -1
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    /// Items checked when the results were last rebuilt, so a pause shows what was saved since.
    private var lastRebuiltAt = 0
    /// The scan has ended and its last results are being built.
    private var isFinishing = false

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
        guard !isScanning, !isFinishing else { return }
        isScanning = true
        hasInterruptedScan = false
        continuation.scanStarted(scanner: environment.scanner)
        publishedRevision = -1
        Task {
            for await p in await environment.scanner.startFullScan() {
                progress = p
                continuation.update(p)
                // Quick wins stored, or a block of photos finished: show what was found so far.
                if p.publishedRevision != publishedRevision {
                    publishedRevision = p.publishedRevision
                    if p.publishedRevision > 0 { scheduleRefresh() }
                } else if p.state == .paused || p.isThermalPaused, p.processed != lastRebuiltAt {
                    // Paused (by the person, the heat, or the system): show everything saved so far.
                    scheduleRefresh()
                }
            }
            isFinishing = true
            isScanning = false
            if progress?.state == .completed { lastScanDate = .now }
            // Rebuild before the system is told the work is over, so the last build is not left
            // to a process that may be suspended at once.
            await refreshTask?.value
            await refreshResults(applyNow: isOnHome)
            continuation.scanEnded()
            isFinishing = false
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

    /// Rebuilds the results from the store and shows them. For a rebuild that must not disturb a
    /// list the person has open, see `refreshResults`.
    func reloadResults() async {
        await refreshResults(applyNow: true)
    }

    /// Rebuilds the results. They replace what is on screen at once when `applyNow`, and are held
    /// as `pendingResults` otherwise.
    func refreshResults(applyNow: Bool) async {
        // A rebuild is stale when a newer one started or the person changed the results
        // meanwhile; try again a few times, then leave the next block to do it.
        for _ in 0..<3 {
            resultsGeneration += 1
            let generation = resultsGeneration
            isBuildingResults = true
            // Reading the store and grouping are heavy for a real library. They must not run on
            // the main thread: iOS ends an app whose launch does not reach the screen within 10
            // seconds, and this did exactly that on a phone with a scanned library.
            let loader = environment.resultsLoader
            let built = await Task.detached(priority: .userInitiated) {
                try? await loader.load()
            }.value
            guard generation == resultsGeneration else { continue }
            isBuildingResults = false
            guard let built else { return }
            lastRebuiltAt = progress?.processed ?? 0
            trace(
                "results built: \(built.categories.map { "\($0.category.rawValue)=\($0.allMembers.count)" }.joined(separator: " "))"
                    + " applyNow=\(applyNow) checked=\(progress?.processed ?? 0)/\(progress?.total ?? 0)")
            if applyNow || results.categories.isEmpty {
                apply(built)
            } else {
                hold(built)
            }
            measureSizesSoon()
            return
        }
    }

    private func trace(_ message: String) {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-TraceScan") {
                print("[scan] \(Date.now.formatted(date: .omitted, time: .standard)) \(message)")
                fflush(stdout)
            }
        #endif
    }

    /// A rebuild is due when the scan reports a new block, and runs one at a time. A rebuild that
    /// took long (a large library full of look-alike photos) is followed by a pause twice as long,
    /// so rebuilding never takes more than a third of the time that the scan could use.
    private func scheduleRefresh() {
        guard refreshTask == nil else {
            refreshAgain = true
            return
        }
        refreshTask = Task {
            repeat {
                refreshAgain = false
                let start = ContinuousClock.now
                await refreshResults(applyNow: isOnHome)
                let took = ContinuousClock.now - start
                if refreshAgain, isScanning { try? await Task.sleep(for: took * 2) }
            } while refreshAgain
            refreshTask = nil
        }
    }

    private func hold(_ new: CleanupResults) {
        pendingResults = new
        let shown = Set(results.categories.flatMap(\.removable))
        pendingNewCount = new.categories.flatMap(\.removable).filter { !shown.contains($0) }.count
    }

    /// Shows the results held back while the person was reviewing.
    func showPendingResults() {
        guard let pending = pendingResults else { return }
        apply(pending)
    }

    func homeAppeared() {
        isOnHome = true
        showPendingResults()
    }

    func homeDisappeared() { isOnHome = false }

    /// Results were changed in place: a build that is still running would bring back
    /// what was just removed, so it is discarded.
    private func invalidateBuild() {
        resultsGeneration += 1
        isBuildingResults = false
    }

    /// Shows `new` with the person's decisions laid over it.
    private func apply(_ new: CleanupResults) {
        let merged = ResultsContinuity.merge(new, choices: choices)
        results = merged.results
        selection = merged.selection
        pendingResults = nil
        pendingNewCount = 0
    }

    /// Replaces size estimates with real sizes. Measuring a photo reads its whole file, so only
    /// the videos (one cheap read each) are measured on their own, and never while a scan runs or
    /// the app is in the background; the photos of a category are measured when it is opened
    /// (spec 008: this used to read every flagged photo in full after each scan).
    private func measureSizesSoon() {
        guard !isScanning else { return }
        Task { await measureSizes(in: .largeVideos) }
    }

    func measureSizes(in category: CleanupCategory, limit: Int = 300) async {
        guard let members = results.category(category)?.allMembers else { return }
        let shown = members.prefix(limit).compactMap { results.items[$0] }
        let updated = await environment.sizeMeasurer.measure(Array(shown))
        for item in updated where results.items[item.assetID] != nil {
            results.items[item.assetID] = item
        }
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
        choices.marks[id] = selection.contains(id)
    }

    func setSelected(_ ids: [String], _ selected: Bool) {
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
        for id in ids { choices.marks[id] = selected }
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
                // A decision the next rebuild must keep.
                choices.keepers.insert(id)
                choices.keepers.subtract(demoted)
                choices.marks[id] = false
                for d in demoted { choices.marks[d] = true }
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
        choices.marks[id] = false
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
                choices.removed.formUnion(removed)
                invalidateBuild()
                results = results.removing(removed)
                pendingResults = pendingResults?.removing(removed)
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
        choices = ReviewChoices()
        apply(.empty)
    }
}
