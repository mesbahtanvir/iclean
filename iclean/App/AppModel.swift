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

    private var changesTask: Task<Void, Never>?

    init(environment: AppEnvironment) {
        self.environment = environment
        self.access = environment.library.authorizationStatus()
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
        access = environment.library.authorizationStatus()
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
        Task {
            for await p in await environment.scanner.startFullScan() {
                progress = p
            }
            isScanning = false
            if progress?.state == .completed { lastScanDate = .now }
            await reloadResults()
        }
    }

    func pauseScan() { Task { await environment.scanner.pause() } }
    func resumeScan() { Task { await environment.scanner.resume() } }
    func stopScan() { Task { await environment.scanner.stop() } }

    // MARK: Results

    func reloadResults() async {
        let items = (try? await environment.store.items()) ?? []
        let keepMarks = (try? await environment.store.keepMarks()) ?? []
        apply(environment.resultsBuilder.buildResults(items: items, keepMarks: keepMarks))
        Task { await measureSizes() }
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
                let protected = group.keepers.filter { results.items[$0]?.metadata.isFavorite == true }
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

    func removeSelected(category: CleanupCategory?, confirmRemoveAll: Bool) async -> CleanupSummary? {
        do {
            let summary = try await environment.remover.remove(
                selection(in: category), in: results, confirmRemoveAll: confirmRemoveAll)
            if !summary.cancelled {
                let removed = Set(summary.removedAssetIDs)
                try? await environment.store.deleteItems(removed)
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

    func clearKeepMarks() async {
        try? await environment.store.clearKeepMarks()
        await reloadResults()
    }

    func deleteAllData() async {
        try? await environment.store.deleteAllData()
        lastScanDate = nil
        hasInterruptedScan = false
        progress = nil
        apply(.empty)
    }
}
