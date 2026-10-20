import Foundation

/// Measures real sizes for items shown in results (research R7). Items whose files
/// are not on the phone keep an estimate and are marked as such.
public actor SizeMeasurer {
    private let library: PhotoLibrary
    private let store: Store
    private var measured: Set<String> = []

    public init(library: PhotoLibrary, store: Store) {
        self.library = library
        self.store = store
    }

    /// Measures items without a measured size and saves just those sizes (never the rest of the
    /// item: results hold slim items, and writing one back would wipe its stored fingerprints).
    /// Returns the updated items.
    public func measure(_ items: [LibraryItem]) async -> [LibraryItem] {
        var updated: [LibraryItem] = []
        var sizes: [String: MeasuredSize] = [:]
        for var item in items where item.byteSize == nil {
            let key =
                "\(item.assetID)|\(item.metadata.modificationDate?.timeIntervalSince1970 ?? 0)"
            guard !measured.contains(key) else { continue }
            measured.insert(key)
            if let bytes = await library.localByteSize(for: item.assetID) {
                item.byteSize = bytes
                item.isSizeEstimated = false
            } else {
                item.byteSize = SizeEstimator.estimate(item.metadata)
                item.isSizeEstimated = true
            }
            sizes[item.assetID] = MeasuredSize(
                bytes: item.byteSize ?? 0, isEstimated: item.isSizeEstimated)
            updated.append(item)
        }
        try? await store.setSizes(sizes)
        return updated
    }
}
