import Foundation

/// Measures real sizes for items shown in results (research R7). Items whose files
/// are not on the phone keep an estimate and are marked as such. Reading a photo's size reads its
/// whole file, so callers ask for a few items at a time, never for a whole library (spec 008).
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
                if item.metadata.kind == .livePhoto {
                    item.motionByteSize = await library.localMotionByteSize(for: item.assetID)
                }
            } else {
                item.byteSize = SizeEstimator.estimate(item.metadata)
                item.isSizeEstimated = true
            }
            sizes[item.assetID] = MeasuredSize(
                bytes: item.byteSize ?? 0, isEstimated: item.isSizeEstimated,
                motionBytes: item.motionByteSize)
            updated.append(item)
        }
        try? await store.setSizes(sizes)
        return updated
    }

    /// Measures every stored video that has no size yet, in one pass: one cheap read each.
    /// A video's size decides what Large Videos lists, so measuring the few on screen at a time
    /// changed the list after each batch and made the results rebuild again and again (spec 008
    /// with 007's rebuild on every store change). Returns how many sizes were written.
    @discardableResult
    public func measureVideos() async -> Int {
        guard let summaries = try? await store.itemSummaries() else { return 0 }
        let videos = summaries.map(\.metadata).filter { $0.kind.isVideo }
        var missing: [AssetMetadata] = []
        for start in stride(from: 0, to: videos.count, by: 500) {
            let slice = Array(videos[start..<min(start + 500, videos.count)])
            let have = (try? await store.sizes(for: slice.map(\.assetID))) ?? [:]
            missing += slice.filter { have[$0.assetID] == nil }
        }
        var sizes: [String: MeasuredSize] = [:]
        for m in missing {
            if let bytes = await library.localByteSize(for: m.assetID) {
                sizes[m.assetID] = MeasuredSize(bytes: bytes, isEstimated: false)
            } else {
                sizes[m.assetID] = MeasuredSize(
                    bytes: SizeEstimator.estimate(m), isEstimated: true)
            }
        }
        // A write that failed reports nothing written, so the caller does not build again for it.
        do { try await store.setSizes(sizes) } catch { return 0 }
        return sizes.count
    }
}
