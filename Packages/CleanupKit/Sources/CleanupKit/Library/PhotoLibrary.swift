import CoreGraphics
import Foundation

/// The only boundary to the Photos library. Implementations never use the network.
public protocol PhotoLibrary: Sendable {
    func authorizationStatus() -> LibraryAccess
    func requestAuthorization() async -> LibraryAccess
    /// Metadata for every item in the user's own library. No pixels.
    func fetchAllItems() async -> [AssetMetadata]
    /// Current metadata for these items only; items no longer in the library are left
    /// out (003: a chunk fetches its own items without enumerating the library).
    func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata]
    /// The few facts that tell whether each of these photos is still the photo that was analyzed.
    /// Cheaper than `fetchItems(withIDs:)`; photos no longer in the library are left out.
    func stamps(forIDs assetIDs: [String]) async -> [String: AssetStamp]
    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult
    /// Pictures of one item for the screen, as a stream: a quick low-resolution one first when that
    /// is all that is on the phone (so a cell is never empty while the better one is made), then the
    /// final one. Ends when the final one has been delivered, and stops the work when the stream is
    /// cancelled (a cell scrolled away). Never downloads. Not for analysis: see `preview`.
    func thumbnails(for assetID: String, pixelSize: Int, fit: ThumbnailFit) -> AsyncStream<
        ThumbnailImage
    >
    /// Tells the library which thumbnails will be asked for soon, so they are ready by then.
    func startPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit)
    /// Tells the library these thumbnails are no longer expected soon.
    func stopPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit)
    /// Size of the item's files on the phone, or nil when not stored locally.
    func localByteSize(for assetID: String) async -> Int64?
    /// Moves items to Recently Deleted. iOS shows its own confirmation first.
    func remove(_ assetIDs: [String]) async -> RemovalResult
    /// Changes made to the library while the app is running.
    func changes() -> AsyncStream<LibraryChange>
}

/// How a thumbnail fills its square: `fill` makes the shorter side the size (a grid cell is cropped
/// to it), `fit` makes the longer side the size (the whole picture, for viewing).
public enum ThumbnailFit: Sendable, Hashable {
    case fill, fit
}

/// One picture of a thumbnail stream. `isFinal` is false for the quick low-resolution first one.
public struct ThumbnailImage: @unchecked Sendable {
    public let image: CGImage
    public let isFinal: Bool

    public init(image: CGImage, isFinal: Bool) {
        self.image = image
        self.isFinal = isFinal
    }
}

extension PhotoLibrary {
    /// For libraries with no faster path (the demo library, tests): the preview, once.
    public func thumbnails(for assetID: String, pixelSize: Int, fit: ThumbnailFit) -> AsyncStream<
        ThumbnailImage
    > {
        AsyncStream { continuation in
            let task = Task {
                if let image = await preview(for: assetID, maxPixels: pixelSize).image {
                    continuation.yield(ThumbnailImage(image: image, isFinal: true))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func startPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit) {}
    public func stopPrefetching(_ assetIDs: [String], pixelSize: Int, fit: ThumbnailFit) {}

    public func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
        let wanted = Set(assetIDs)
        return await fetchAllItems().filter { wanted.contains($0.assetID) }
    }

    public func stamps(forIDs assetIDs: [String]) async -> [String: AssetStamp] {
        var out: [String: AssetStamp] = [:]
        for m in await fetchItems(withIDs: assetIDs) { out[m.assetID] = AssetStamp(m) }
        return out
    }
}

/// What tells whether a photo changed since it was analyzed.
public struct AssetStamp: Sendable, Equatable {
    public var modificationDate: Date?
    public var isFavorite: Bool
    public var hasAdjustments: Bool
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        modificationDate: Date?, isFavorite: Bool, hasAdjustments: Bool, pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.modificationDate = modificationDate
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public init(_ m: AssetMetadata) {
        self.init(
            modificationDate: m.modificationDate, isFavorite: m.isFavorite,
            hasAdjustments: m.hasAdjustments, pixelWidth: m.pixelWidth, pixelHeight: m.pixelHeight)
    }
}

public enum PreviewResult: @unchecked Sendable {
    /// The full-quality item is on the phone.
    case local(CGImage)
    /// Only a low-resolution preview is on the phone.
    case cloudPreview(CGImage)
    /// Nothing usable on the phone; counted as "not scanned".
    case unavailable

    public var image: CGImage? {
        switch self {
        case .local(let image), .cloudPreview(let image): image
        case .unavailable: nil
        }
    }

    public var source: AnalysisSource {
        switch self {
        case .local: .localPreview
        case .cloudPreview: .cloudPreview
        case .unavailable: .notScanned
        }
    }
}

public struct RemovalResult: Sendable, Equatable {
    public var removed: [String]
    public var failed: [String]
    /// The user cancelled the iOS confirmation; nothing was removed.
    public var cancelled: Bool

    public init(removed: [String], failed: [String], cancelled: Bool = false) {
        self.removed = removed
        self.failed = failed
        self.cancelled = cancelled
    }
}

public struct LibraryChange: Sendable, Equatable {
    public var insertedOrChanged: Set<String>
    public var removed: Set<String>

    public init(insertedOrChanged: Set<String> = [], removed: Set<String> = []) {
        self.insertedOrChanged = insertedOrChanged
        self.removed = removed
    }
}
