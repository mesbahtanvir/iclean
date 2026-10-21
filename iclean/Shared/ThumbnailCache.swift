import CleanupKit
import CoreGraphics
import Foundation

/// Pictures already fetched for the screen, so a cell that scrolls back into view has its picture
/// on its first frame and never asks PhotoKit again. Holds decoded images up to a size limit; the
/// system also empties it under memory pressure (`NSCache`).
final class ThumbnailCache: @unchecked Sendable {
    private final class Entry {
        let picture: ThumbnailImage
        init(_ picture: ThumbnailImage) { self.picture = picture }
    }

    private let cache = NSCache<NSString, Entry>()

    init(megabytes: Int = 96) {
        cache.totalCostLimit = megabytes * 1_048_576
    }

    private func key(_ assetID: String, _ pixelSize: Int, _ fit: ThumbnailFit) -> NSString {
        "\(assetID)|\(pixelSize)|\(fit == .fill ? "fill" : "fit")" as NSString
    }

    func picture(for assetID: String, pixelSize: Int, fit: ThumbnailFit) -> ThumbnailImage? {
        cache.object(forKey: key(assetID, pixelSize, fit))?.picture
    }

    func store(_ picture: ThumbnailImage, for assetID: String, pixelSize: Int, fit: ThumbnailFit) {
        let k = key(assetID, pixelSize, fit)
        // The quick low-resolution picture never replaces the final one.
        if !picture.isFinal, cache.object(forKey: k)?.picture.isFinal == true { return }
        let cost = picture.image.width * picture.image.height * 4
        cache.setObject(Entry(picture), forKey: k, cost: cost)
    }

    /// For when the library changed: an edited photo must be fetched again.
    func removeAll() { cache.removeAllObjects() }
}
