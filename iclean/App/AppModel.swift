import CleanupKit
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

/// Where the launch is: opening the saved data, building results from scratch, ready, or unable
/// to read the saved data. The screens never claim "clean" before the state is known.
enum LaunchPhase: Equatable {
    case opening
    case building
    case ready
    case failed
}

/// A problem with the saved data that the person is told about (never hidden as "empty").
enum StoreProblem: Equatable {
    /// The saved data could not be opened; this run keeps nothing.
    case volatile(String)
    /// The saved data opened but could not be read.
    case unreadable(String)
}

/// A route to push at launch, with a token so a screen applies each one once.
struct RestoredRoute: Equatable {
    let id = UUID()
    let path: [Route]
}

/// App state: access, scanning, results, review choices and removal.
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
    /// Something went wrong that the person must be told about (shown by Home as an alert).
    var errorMessage: String?
    /// Why the last removal did not happen, shown inside the confirm sheet.
    var removalError: String?
    /// Keeps a scan going after the user leaves the app (002).
    let continuation: any ScanKeepAlive = makePlatformScanKeepAlive()
    /// True while results are being built, so the screen does not claim "clean" meanwhile.
    var isBuildingResults = false
    /// Where the launch is (specs/007-persistent-session).
    var launchPhase: LaunchPhase = .opening
    var storeProblem: StoreProblem?
    /// The review stack to put the person back on, applied once by Home.
    var restoredRoute: RestoredRoute?
    /// The photo a restored screen scrolls to, until the person touches anything or moves on.
    var restoredFocus: String?
    private var restoredPath: [Route] = []
    /// A review stack Home offers as "Continue reviewing" (too old, or a restore failed before).
    var continueRoute: [Route] = []
    /// Newer results are waiting for the person to leave the screen they are looking at.
    var hasPendingResults: Bool { pendingBuild != nil }

    /// Tells a finished build whether it is still the newest one.
    private var resultsGeneration = 0
    /// How many items the results held in `pendingBuild` would add to the screen.
    private(set) var pendingNewCount = 0
    /// Photos removed in this run. A scan still in flight can bring one back into the store,
    /// so every build drops them (spec 008).
    private var removedInSession: Set<String> = []
    private var publishedRevision = -1
    /// Items checked when the results were last rebuilt, so a pause shows what was saved since.
    private var lastRebuiltAt = 0
    /// The scan has ended and its last results are being built.
    private var isFinishing = false

    private var changesTask: Task<Void, Never>?

    // Saved state (specs/007-persistent-session).
    private var intent = ReviewIntent()
    private var position = ReviewPosition()
    private var keepMarks: Set<String> = []
    /// The store revision the results on screen were built for.
    private var basisRevision: Int64?
    private var pendingBuild: PendingBuild? {
        didSet { if pendingBuild == nil { pendingNewCount = 0 } }
    }
    private var pathIsEmpty = true
    private var launched = false
    private var reconciling = false
    /// Delete All Data is under way: nothing may start writing or publishing meanwhile.
    private var isDeleting = false
    /// The saved review state was read at launch. Until it was, nothing may be written over it.
    private var stateLoaded = false
    private var rebuildTask: Task<Void, Never>?
    private var rebuildAgain = false
    private let writer: ReviewStateWriter
    private var writerGeneration = 0

    private struct PendingBuild {
        var results: CleanupResults
        var revision: Int64
        var keepMarks: Set<String>
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        self.access = environment.library.authorizationStatus()
        self.writer = ReviewStateWriter(store: environment.store)
        continuation.onAutoResume = { [weak self] in self?.resumeScan() }
    }

    // MARK: Lifecycle

    func onLaunch() async {
        guard !launched else { return }
        launched = true
        if case .volatile(let why) = await environment.store.openStatus() {
            storeProblem = .volatile(why)
        }
        writerGeneration = await writer.currentGeneration()
        let state: LaunchState
        do {
            state = try await environment.store.loadLaunchState()
        } catch {
            // Never read as "no results": say the saved data could not be read.
            storeProblem = .unreadable(error.localizedDescription)
            launchPhase = .failed
            return
        }
        stateLoaded = true
        hasInterruptedScan = state.session?.isActive ?? false
        lastScanDate = state.session?.finishedAt
        keepMarks = state.keepMarks
        intent =
            Self.decode(ReviewIntent.self, state.states[.decisions], ReviewIntent.formatVersion)
            ?? ReviewIntent()
        intent.expire()
        position =
            Self.decode(ReviewPosition.self, state.states[.position], ReviewPosition.formatVersion)
            ?? ReviewPosition()

        // The saved results are shown only if they are provably the results of what is in the store.
        let key = builderKey()
        let envelope = state.states[.results]
        let outcome = await Task.detached(priority: .userInitiated) {
            SnapshotRestore.restore(
                envelope, expecting: key, revision: state.revision, itemCount: state.itemCount,
                keepMarkCount: state.keepMarks.count)
        }.value
        if let restored = outcome.results {
            trace("results restored from the saved snapshot (\(restored.items.count) items)")
            apply(restored, revision: state.revision, keepMarks: state.keepMarks)
            launchPhase = .ready
            await overlayStoredSizes()
            measureSizesSoon()
        } else {
            launchPhase = .building
            // A read that fails is a failure to say so, never "your library looks clean".
            guard await rebuild(firstPublish: true) else {
                launchPhase = .failed
                return
            }
            launchPhase = .ready
        }
        await checkVisibleSet()
        await beginRestoringPosition()
        observeLibraryChanges()
        await reconcile()
    }

    /// Quick check for new or changed photos each time the app opens (FR-005a).
    func onForeground() async {
        continuation.appWillEnterForeground()
        access = environment.library.authorizationStatus()
        // The first active phase of a launch is part of the launch, not a second visit.
        guard launchPhase == .ready, !reconciling, !isDeleting,
            access == .full || access == .limited,
            !isScanning, !hasInterruptedScan, lastScanDate != nil
        else { return }
        await reconcile()
    }

    /// Looks for changes since the last visit, and rebuilds only if the store moved on.
    private func reconcile() async {
        guard !reconciling, !isDeleting, access == .full || access == .limited, !isScanning,
            !hasInterruptedScan, lastScanDate != nil
        else { return }
        reconciling = true
        defer { reconciling = false }
        _ = await environment.scanner.quickCheck()
        guard !isDeleting else { return }
        let current = try? await environment.store.revision()
        if let current, current != basisRevision { await rebuild() }
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
                    if p.publishedRevision > 0 { scheduleRebuild() }
                } else if p.state == .paused || p.isThermalPaused, p.processed != lastRebuiltAt {
                    // Paused (by the person, the heat, or the system): show everything saved so far.
                    scheduleRebuild()
                }
            }
            isFinishing = true
            isScanning = false
            if progress?.state == .completed { lastScanDate = .now }
            // Rebuild before the system is told the work is over, so the last build is not left
            // to a process that may be suspended at once.
            await rebuildTask?.value
            await reloadResults()
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

    /// Builds the results again from what is stored, off the main thread.
    func reloadResults() async {
        // A scan that finishes after a failed read has fresh, readable results to show.
        if await rebuild(), launchPhase == .failed, stateLoaded {
            storeProblem = nil
            launchPhase = .ready
        }
    }

    /// Builds again in the background, one at a time: requests that arrive meanwhile are one more
    /// build afterwards, not a queue. A build that took long (a large library full of look-alike
    /// photos) is followed by a pause twice as long while a scan runs, so building never takes more
    /// than a third of the time the scan could use (spec 008).
    private func scheduleRebuild() {
        guard !isDeleting else { return }
        guard rebuildTask == nil else {
            rebuildAgain = true
            return
        }
        rebuildTask = Task { [weak self] in
            repeat {
                self?.rebuildAgain = false
                let start = ContinuousClock.now
                await self?.rebuild()
                let took = ContinuousClock.now - start
                if self?.rebuildAgain == true, self?.isScanning == true {
                    try? await Task.sleep(for: took * 2)
                }
            } while self?.rebuildAgain == true
            self?.rebuildTask = nil
        }
    }

    /// Returns false when the stored items could not be read. A build that was overtaken by a
    /// newer one is not a failure.
    @discardableResult
    private func rebuild(firstPublish: Bool = false) async -> Bool {
        resultsGeneration += 1
        let generation = resultsGeneration
        isBuildingResults = true
        let inputs: ResultInputs
        do {
            inputs = try await environment.store.resultInputs()
        } catch {
            guard generation == resultsGeneration else { return true }
            isBuildingResults = false
            // A read that fails is a failure to say so, never "your library looks clean": with
            // nothing to show the screen says so, with results already shown they stay but carry
            // the warning.
            storeProblem = .unreadable(error.localizedDescription)
            if results.categories.isEmpty, launchPhase == .ready { launchPhase = .failed }
            return false
        }
        // Grouping is CPU-heavy for a real library. It must not run on the main thread:
        // iOS ends an app whose launch does not reach the screen within 10 seconds, and
        // this did exactly that on a phone with a scanned library.
        let builder = environment.resultsBuilder
        let built = await Task.detached(priority: .userInitiated) {
            builder.buildResults(items: inputs.items, keepMarks: inputs.keepMarks).slimmed()
        }.value
        // A newer build, or a change made to the results meanwhile, makes this one stale.
        guard generation == resultsGeneration else { return true }
        isBuildingResults = false
        guard !isDeleting else { return true }
        // A read that works again clears an earlier "could not read" warning.
        if case .unreadable = storeProblem { storeProblem = nil }
        lastRebuiltAt = progress?.processed ?? 0
        trace(
            "results built: \(built.categories.map { "\($0.category.rawValue)=\($0.allMembers.count)" }.joined(separator: " "))"
                + " onHome=\(pathIsEmpty) checked=\(progress?.processed ?? 0)/\(progress?.total ?? 0)"
        )
        if firstPublish || pathIsEmpty {
            apply(built, revision: inputs.revision, keepMarks: inputs.keepMarks)
            measureSizesSoon()
        } else {
            // The person is looking at a list: it does not change under their finger. The new
            // results are applied when they are back on Home, or when they ask for them.
            hold(
                PendingBuild(
                    results: built, revision: inputs.revision, keepMarks: inputs.keepMarks))
        }
        // A running scan moves the store with every chunk, so a snapshot made now would be refused
        // as stale by the time it is written; it is saved when the scan pauses or ends.
        if !scanIsWriting { saveSnapshot(built, inputs: inputs) }
        return true
    }

    /// The scan is running and saving chunks, as opposed to paused, hot, or over.
    private var scanIsWriting: Bool {
        isScanning && progress?.state == .running && progress?.isThermalPaused != true
    }

    /// Saves the results, but only if the store has not moved on since they were built.
    private func saveSnapshot(_ built: CleanupResults, inputs: ResultInputs) {
        // Results of an empty store are not worth keeping, and a store that was just emptied (Delete
        // All Data) must read as holding nothing saved.
        guard !inputs.items.isEmpty else { return }
        let store = environment.store
        let key = builderKey()
        let itemCount = inputs.items.count
        let marks = inputs.keepMarks.count
        let revision = inputs.revision
        Task.detached(priority: .utility) {
            let snapshot = ResultsSnapshot(
                results: built, builderKey: key, itemCount: itemCount, keepMarkCount: marks)
            guard let payload = try? StateCodec.seal(snapshot) else { return }
            _ = try? await store.saveSnapshot(
                payload, version: ResultsSnapshot.formatVersion, ifRevision: revision)
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

    /// Holds newer results back while a list is open, and counts what they would add.
    private func hold(_ pending: PendingBuild) {
        pendingBuild = pending
        let shown = Set(results.categories.flatMap(\.removable))
        pendingNewCount =
            pending.results.categories.flatMap(\.removable).filter { !shown.contains($0) }.count
    }

    /// Shows the results held back while the person was reviewing ("N new results. Show").
    func showPendingResults() { applyPendingIfAny() }

    /// Results were changed in place: a build that is still running would bring back
    /// what was just removed, so it is discarded.
    private func invalidateBuild() {
        resultsGeneration += 1
        isBuildingResults = false
        pendingBuild = nil
    }

    /// A change made in place: photos removed, kept for good, or changed elsewhere. The results go
    /// through the same applier as a rebuild, so the selection is always the suggestions plus the
    /// person's decisions (a group that lost its keeper gets a new one, a group that fell apart
    /// leaves nobody ticked), and a build from the store follows in the background.
    private func patch(removing gone: Set<String>) {
        let held = pendingBuild
        invalidateBuild()
        if var held {
            held.results = held.results.removing(gone)
            hold(held)
        }
        results = results.removing(gone)
        let applied = intent.apply(to: results, keepMarks: keepMarks)
        results = applied.results
        selection = applied.selection
        scheduleRebuild()
    }

    /// Photos found to be deleted or changed outside iclean: out of the store (a changed one is
    /// analyzed again by the next check), out of the lists, and the results are built again.
    private func photosChangedElsewhere(_ ids: Set<String>) async {
        guard !ids.isEmpty, !isDeleting else { return }
        try? await environment.store.deleteItems(ids)
        patch(removing: ids)
    }

    /// Checks what is shown against the library as it is now. Changes made while iclean was closed
    /// are not replayed by Photos, so a restored list could show a photo deleted or edited since.
    private func checkVisibleSet() async {
        guard access == .full || access == .limited else { return }
        let shown = results.categories.flatMap(\.allMembers)
        guard !shown.isEmpty else { return }
        var changed: Set<String> = []
        // In batches, so a library of 30,000 never makes one huge query to Photos.
        for start in stride(from: 0, to: shown.count, by: 1_000) {
            let batch = Array(shown[start..<min(start + 1_000, shown.count)])
            let now = await environment.library.stamps(forIDs: batch)
            guard !isDeleting else { return }
            for id in batch {
                guard let stamp = now[id] else {
                    changed.insert(id)
                    continue
                }
                guard let stored = results.items[id]?.metadata else { continue }
                if stamp != AssetStamp(stored) { changed.insert(id) }
            }
        }
        await photosChangedElsewhere(changed)
    }

    /// Shows results with the person's choices applied on top, so a rebuild never undoes them.
    private func apply(_ new: CleanupResults, revision: Int64, keepMarks: Set<String>) {
        self.keepMarks = keepMarks
        let applied = intent.apply(to: new.removing(removedInSession), keepMarks: keepMarks)
        results = applied.results
        selection = applied.selection
        basisRevision = revision
        pendingBuild = nil
    }

    /// Replaces the results on screen by the newer ones that were waiting.
    private func applyPendingIfAny() {
        guard let pending = pendingBuild else { return }
        apply(pending.results, revision: pending.revision, keepMarks: pending.keepMarks)
        measureSizesSoon()
    }

    private func builderKey() -> BuilderKey {
        BuilderKey(
            detectors: Detectors.all(environment.features).map(\.category),
            features: environment.features, access: access)
    }

    private static func decode<T: Decodable>(
        _ type: T.Type, _ envelope: StateEnvelope?, _ version: Int
    ) -> T? {
        guard let envelope, envelope.version == version else { return nil }
        return try? StateCodec.open(envelope.payload, as: type)
    }

    /// Sizes measured before the snapshot was saved arrive in the store, not in the snapshot.
    private func overlayStoredSizes() async {
        let ids = results.categories.flatMap(\.allMembers).filter {
            results.items[$0]?.byteSize == nil
        }
        guard !ids.isEmpty, let sizes = try? await environment.store.sizes(for: ids) else { return }
        for (id, size) in sizes {
            results.items[id]?.byteSize = size.bytes
            results.items[id]?.isSizeEstimated = size.isEstimated
        }
    }

    /// Replaces size estimates with real sizes. Measuring a photo reads its whole file, so only
    /// the videos (one cheap read each) are measured on their own, and never while a scan runs or
    /// the app is in the background; the photos of a category are measured when it is opened
    /// (spec 008: this used to read every flagged photo in full after each scan).
    ///
    /// All videos are measured at once, because a video's size decides which ones Large Videos
    /// lists: the few on screen at a time would change the list after every batch, and each change
    /// builds the results again. Once they all have a size, the one rebuild that follows is the last.
    private func measureSizesSoon() {
        guard !isScanning else { return }
        Task {
            if await environment.sizeMeasurer.measureVideos() > 0 { scheduleRebuild() }
        }
    }

    func measureSizes(in category: CleanupCategory, limit: Int = 300) async {
        guard let members = results.category(category)?.allMembers else { return }
        let shown = members.prefix(limit).compactMap { results.items[$0] }
        let updated = await environment.sizeMeasurer.measure(Array(shown))
        guard !updated.isEmpty else { return }
        for item in updated where results.items[item.assetID] != nil {
            results.items[item.assetID]?.byteSize = item.byteSize
            results.items[item.assetID]?.isSizeEstimated = item.isSizeEstimated
        }
        // A measured size can change which copy is kept; if the store moved, build once, quietly.
        if let current = try? await environment.store.revision(), current != basisRevision {
            await rebuild()
        }
    }

    private func observeLibraryChanges() {
        guard changesTask == nil, access == .full || access == .limited else { return }
        let stream = environment.library.changes()
        changesTask = Task { [weak self] in
            for await change in stream {
                guard let self else { return }
                // Items deleted or changed elsewhere are dropped from results.
                await self.photosChangedElsewhere(change.removed.union(change.insertedOrChanged))
            }
        }
    }

    // MARK: Selection and keepers

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func toggle(_ id: String) {
        let on = !selection.contains(id)
        if on { selection.insert(id) } else { selection.remove(id) }
        intent.setSelected([id], on, keepers: suggestedKeepers)
        noteFocus(id)
        saveDecisions()
    }

    func setSelected(_ ids: [String], _ selected: Bool) {
        if selected { selection.formUnion(ids) } else { selection.subtract(ids) }
        intent.setSelected(ids, selected, keepers: suggestedKeepers)
        saveDecisions()
    }

    /// The photos the results suggest keeping right now, to tell a tick on a keeper from a tick
    /// on an ordinary copy.
    private var suggestedKeepers: Set<String> {
        Set(
            results.categories.flatMap {
                $0.groups.filter { $0.type != .single }.flatMap(\.keepers)
            })
    }

    func selectedCount(in category: CleanupCategory) -> Int {
        results.category(category)?.allMembers.filter(selection.contains).count ?? 0
    }

    /// Makes `id` the keeper of its group; the previous keeper becomes removable
    /// (Story 1 scenario 2). Favorites always stay keepers.
    func makeKeeper(_ id: String) {
        guard results.group(containing: id) != nil else { return }
        intent.chooseKeeper(id)
        noteFocus(id)
        let applied = intent.apply(to: results, keepMarks: keepMarks)
        results = applied.results
        selection = applied.selection
        saveDecisions()
    }

    /// Never flag this item again (FR-011).
    func alwaysKeep(_ id: String) async {
        try? await environment.store.setKeep(id, true)
        keepMarks.insert(id)
        intent.forget([id])
        patch(removing: [id])
        saveDecisions()
    }

    /// Hands the newest choices to the writer. What only repeats the defaults is left out.
    private func saveDecisions() {
        // Before the results are shown the suggestions are not known, so nothing can be compared
        // with them, and what is saved must not be overwritten by what is merely not loaded yet.
        guard launchPhase == .ready else { return }
        let defaults = ReviewIntent.defaults(for: results, keepMarks: keepMarks)
        let saved = intent.normalized(against: defaults)
        let generation = writerGeneration
        Task { await writer.update(decisions: saved, generation: generation) }
    }

    // MARK: Position

    /// Called by Home whenever the pushed screens change.
    func pathChanged(_ path: [Route]) {
        pathIsEmpty = path.isEmpty
        position.path = path
        position.savedAt = .now
        if path.isEmpty { continueRoute = [] }
        // Any move after the restore itself means the person is somewhere else now.
        if path != restoredPath { restoredFocus = nil }
        savePosition()
        if path.isEmpty { applyPendingIfAny() }
    }

    /// The photo last touched, so a restored list can scroll to it.
    func noteFocus(_ assetID: String) {
        restoredFocus = nil
        guard position.focusAssetID != assetID else { return }
        position.focusAssetID = assetID
        position.savedAt = .now
        savePosition()
    }

    private func savePosition() {
        guard launchPhase == .ready else { return }
        let saved = position
        let generation = writerGeneration
        Task { await writer.update(position: saved, generation: generation) }
    }

    private func beginRestoringPosition() async {
        let valid = RouteValidator.validate(position.path, in: results)
        guard !valid.isEmpty else {
            position.path = []
            return
        }
        guard position.shouldAutoRestore() else {
            continueRoute = valid
            return
        }
        // The attempt is counted, durably, before the screen is built: if building it crashes the
        // app, the next launch sees the count and stops restoring by itself.
        position.restoreAttempts += 1
        position.path = valid
        await writer.update(position: position, generation: writerGeneration)
        await writer.flush()
        restoredPath = valid
        restoredFocus = position.focusAssetID.flatMap { results.items[$0] == nil ? nil : $0 }
        restoredRoute = RestoredRoute(path: valid)
        // A restore that has survived a while proves the screen did not crash.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.clearRestoreAttempts()
        }
    }

    private func clearRestoreAttempts() async {
        guard position.restoreAttempts > 0 else { return }
        position.restoreAttempts = 0
        await writer.update(position: position, generation: writerGeneration)
    }

    /// The person taps "Continue reviewing".
    func continueReviewing() {
        // Checked again now: the results may have changed since the row was offered.
        let valid = RouteValidator.validate(continueRoute, in: results)
        continueRoute = []
        guard !valid.isEmpty else { return }
        restoredPath = valid
        restoredFocus = position.focusAssetID.flatMap { results.items[$0] == nil ? nil : $0 }
        restoredRoute = RestoredRoute(path: valid)
    }

    /// The person dismisses "Continue reviewing".
    func dismissContinue() {
        continueRoute = []
        position.path = []
        let saved = position
        let generation = writerGeneration
        Task { await writer.update(position: saved, generation: generation) }
    }

    /// Writes everything unsaved before the app can be suspended. Called, synchronously, when the
    /// app goes inactive or to the background; the background task keeps it alive until the write
    /// is done. Nothing depends on being told the app is about to be killed: it is not told.
    func flushForBackground() {
        // Nothing is written until the saved state has been read and the results are shown: an
        // early write would replace the saved choices with empty ones.
        guard launchPhase == .ready, !isDeleting else { return }
        #if canImport(UIKit)
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "iclean.saveState") {
                UIApplication.shared.endBackgroundTask(task)
            }
            let id = task
        #endif
        let generation = writerGeneration
        position.restoreAttempts = 0
        let savedPosition = position
        let defaults = ReviewIntent.defaults(for: results, keepMarks: keepMarks)
        let savedIntent = intent.normalized(against: defaults)
        Task {
            await writer.update(
                decisions: savedIntent, position: savedPosition, generation: generation)
            await writer.flush()
            #if canImport(UIKit)
                UIApplication.shared.endBackgroundTask(id)
            #endif
        }
    }

    /// Writes what is unsaved and waits for it (before the confirm sheet and before a removal).
    func flushNow() async {
        guard launchPhase == .ready, !isDeleting else { return }
        let defaults = ReviewIntent.defaults(for: results, keepMarks: keepMarks)
        await writer.update(
            decisions: intent.normalized(against: defaults), position: position,
            generation: writerGeneration)
        await writer.flush()
    }

    // MARK: Removal

    /// The selected items in one category, or everywhere when `category` is nil.
    func selection(in category: CleanupCategory?) -> Set<String> {
        guard let category else { return selection }
        return selection.intersection(results.category(category)?.allMembers ?? [])
    }

    /// Checks the selection against the Photos library as it is now and fixes what a removal will
    /// do. The confirm sheet shows this plan and Remove carries out exactly it, whatever happens to
    /// the results meanwhile.
    func makeRemovalPlan(category: CleanupCategory?) async -> RemovalPlan {
        await flushNow()
        return await RemovalGate.plan(
            selection: selection(in: category), results: results, library: environment.library)
    }

    func removalPreview(_ plan: RemovalPlan) -> RemovalPreview {
        environment.remover.summary(for: plan.ids, in: plan.results)
    }

    func remove(_ plan: RemovalPlan, confirmRemoveAll: Bool) async -> CleanupSummary? {
        do {
            let summary = try await environment.remover.remove(
                plan.ids, in: plan.results, confirmRemoveAll: confirmRemoveAll)
            if !summary.cancelled {
                let removed = Set(summary.removedAssetIDs)
                try? await environment.store.deleteItems(removed)
                removedInSession.formUnion(removed)
                intent.forget(removed)
                patch(removing: removed)
                saveDecisions()
                Log.removal.info("Removed \(summary.removedCount) items")
            }
            lastSummary = summary
            return summary
        } catch {
            removalError = String(localized: "Nothing was removed.")
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
        keepMarks = []
        await reloadResults()
    }

    // MARK: Saved data

    struct SavedDataInventory {
        var resultsBytes: Int?
        var resultsBuiltAt: Date?
        var decisionCount: Int
        var keeperChoices: Int
        var hasPosition: Bool
    }

    /// What is saved besides the scan itself, for the "Saved on this iPhone" screen.
    func savedDataInventory() async -> SavedDataInventory {
        let info = (try? await environment.store.stateInfo()) ?? [:]
        return SavedDataInventory(
            resultsBytes: info[.results]?.bytes, resultsBuiltAt: info[.results]?.updatedAt,
            decisionCount: intent.forcedOn.count + intent.forcedOff.count,
            keeperChoices: intent.keeperChoices.count, hasPosition: !position.path.isEmpty)
    }

    /// Deletes the saved results. They are rebuilt from the scan next time; nothing is lost.
    func clearSavedResults() async {
        try? await environment.store.deleteState([.results])
    }

    /// Forgets the selections, keeper choices and place in the review. Suggestions go back to the
    /// defaults. The scan, the results and the "Always Keep" list stay.
    func resetReviewChoices() async {
        await writer.invalidate()
        writerGeneration = await writer.currentGeneration()
        intent = ReviewIntent()
        position = ReviewPosition()
        continueRoute = []
        try? await environment.store.deleteState([.decisions, .position])
        // The results on screen carry the keepers the person chose; the suggestions come from a
        // fresh build.
        await rebuild(firstPublish: true)
    }

    /// Deletes the damaged store files and starts again with an empty store. Only offered when the
    /// saved data could not be opened or read; everything else deletes rows (`deleteAllData`).
    func eraseSavedData() async {
        isDeleting = true
        // The same as Delete All Data: nothing may write into the store while it is replaced.
        await environment.scanner.stop()
        await eraseStoreAndRestart()
        isDeleting = false
    }

    private func eraseStoreAndRestart() async {
        await writer.invalidate()
        try? await environment.store.eraseStoreFiles()
        intent = ReviewIntent()
        position = ReviewPosition()
        pendingBuild = nil
        restoredRoute = nil
        continueRoute = []
        resultsGeneration += 1
        isBuildingResults = false
        results = .empty
        selection = []
        keepMarks = []
        removedInSession = []
        basisRevision = nil
        storeProblem = nil
        lastScanDate = nil
        hasInterruptedScan = false
        progress = nil
        stateLoaded = false
        launched = false
        launchPhase = .opening
        await onLaunch()
    }

    /// Deletes everything iclean saved. Returns whether it all went.
    @discardableResult
    func deleteAllData() async -> Bool {
        isDeleting = true
        // Anything that writes is stopped first: a scan, or the quick check that runs when the app
        // opens, would otherwise save its items and a finished session right after the delete.
        await environment.scanner.stop()
        // If the saved data could not be opened, the damaged files are what has to go.
        if storeProblem != nil {
            await eraseStoreAndRestart()
            isDeleting = false
            isBuildingResults = false
            if storeProblem != nil {
                errorMessage = String(
                    localized: "Couldn't delete the saved data. Your photos are untouched.")
                return false
            }
            return true
        }
        // Nothing pending may be written back after the delete: cancel the writer first, clear what
        // is held in memory, and only then delete.
        await writer.invalidate()
        writerGeneration = await writer.currentGeneration()
        intent = ReviewIntent()
        position = ReviewPosition()
        pendingBuild = nil
        restoredRoute = nil
        continueRoute = []
        resultsGeneration += 1
        isBuildingResults = false
        do {
            try await environment.store.deleteAllData()
        } catch {
            // Say so, and show what is really still saved.
            errorMessage = String(
                localized: "Couldn't delete everything. Your photos are untouched.")
            isDeleting = false
            stateLoaded = false
            launched = false
            launchPhase = .opening
            await onLaunch()
            return false
        }
        keepMarks = []
        removedInSession = []
        basisRevision = try? await environment.store.revision()
        lastScanDate = nil
        hasInterruptedScan = false
        progress = nil
        results = .empty
        selection = []
        // A build that was already reading the store must not publish what it read before the delete.
        resultsGeneration += 1
        isBuildingResults = false
        isDeleting = false
        return true
    }
}
