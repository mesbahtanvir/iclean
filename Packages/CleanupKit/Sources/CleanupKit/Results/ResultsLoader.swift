import Foundation

/// Builds results from the store without holding every fingerprint in memory (spec 008).
///
/// `Store.items()` needs about 20 KB of memory per item, so 30,000 items cost more than 600 MB
/// before a single detector ran, and the app did that after every scan, at every launch and on
/// every return to the foreground. Here the items are read without their feature prints (the
/// larger blob), the prints are read only for the photos that have a neighbour within the
/// similar-shots window (about a third of a library), and the builder gets exactly what it would
/// have got from `items()`: no detector ever looks at a feature print this loader left out, so
/// the results are the same: categories, groups, keepers, selection and counts. Only the stored
/// feature print of a photo with no neighbour is missing from `CleanupResults.items`, and nothing
/// reads it there.
public struct ResultsLoader: Sendable {
    private let store: Store
    private let builder: ResultsBuilder

    public init(store: Store, builder: ResultsBuilder) {
        self.store = store
        self.builder = builder
    }

    public func load() async throws -> CleanupResults {
        var items = try await store.itemsWithoutFeaturePrints()
        let keepMarks = try await store.keepMarks()
        let wanted = SimilarShotsDetector.photosThatMayNeedFeaturePrints(items)
        let prints = try await store.featurePrints(for: wanted)
        for i in items.indices where items[i].analysis != nil {
            if let print = prints[items[i].assetID] { items[i].analysis?.featurePrint = print }
        }
        return builder.buildResults(items: items, keepMarks: keepMarks)
    }
}

extension SimilarShotsDetector {
    /// The photos whose feature print the detector can compare: those with another photo within
    /// the window. Computed over all analyzed photos, which is a superset of what any detector
    /// receives (an earlier category may take photos away, never add any): if two photos are
    /// within the window, so is every photo between them in time, so each of the two is within
    /// the window of its neighbour in the sorted list.
    static func photosThatMayNeedFeaturePrints(_ items: [LibraryItem]) -> [String] {
        let photos =
            items
            .filter {
                ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil
            }
            .sorted {
                ($0.metadata.captureDate ?? .distantPast)
                    < ($1.metadata.captureDate ?? .distantPast)
            }
        var wanted: [String] = []
        for i in photos.indices {
            guard let date = photos[i].metadata.captureDate else { continue }
            let next = i + 1 < photos.count ? photos[i + 1].metadata.captureDate : nil
            let before = i > 0 ? photos[i - 1].metadata.captureDate : nil
            let nextClose =
                next.map { $0.timeIntervalSince(date) <= SimilarThresholds.window } ?? false
            let beforeClose =
                before.map { date.timeIntervalSince($0) <= SimilarThresholds.window } ?? false
            if nextClose || beforeClose { wanted.append(photos[i].assetID) }
        }
        return wanted
    }
}
