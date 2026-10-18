import AVFoundation
import CleanupKit
import CoreGraphics
import Foundation
import ImageIO

/// A photo library made of the rendered baseline files, with no Photos framework. It lets
/// the whole check run on a development machine, where the catalog is calibrated, before
/// the same catalog goes through the real library on a device.
public final class RenderedPhotoLibrary: PhotoLibrary, @unchecked Sendable {
    private let catalog: BaselineCatalog
    private let files: [String: RenderedFile]
    private let ordered: [BaselineAsset]

    public init(catalog: BaselineCatalog, rendered: [String: RenderedFile]) {
        self.catalog = catalog
        files = rendered
        ordered = catalog.assets.sorted { $0.captureDate < $1.captureDate }
    }

    public func authorizationStatus() -> LibraryAccess { .full }
    public func requestAuthorization() async -> LibraryAccess { .full }

    public func fetchAllItems() async -> [AssetMetadata] { ordered.compactMap(metadata) }

    private func metadata(_ asset: BaselineAsset) -> AssetMetadata? {
        guard let file = files[asset.id] else { return nil }
        let kind: ItemKind =
            switch asset.kind {
            case .photo: .photo
            case .screenshot: .screenshot
            case .video: .video
            }
        var duration: Double?
        if case .video(_, let seconds) = asset.recipe.base { duration = seconds }
        return AssetMetadata(
            assetID: asset.id, kind: kind, captureDate: asset.captureDate,
            modificationDate: asset.captureDate, pixelWidth: file.width, pixelHeight: file.height,
            duration: duration, isFavorite: asset.favorite,
            albumNames: [catalog.albumTitle] + asset.albums, hasLocation: asset.location)
    }

    public func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
        guard let file = files[assetID], let asset = catalog.asset(id: assetID) else { return .unavailable }
        if asset.kind == .video {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            guard let image = try? await generator.image(at: .zero).image else { return .unavailable }
            return .local(image)
        }
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        else { return .unavailable }
        return .local(image)
    }

    public func localByteSize(for assetID: String) async -> Int64? { files[assetID]?.bytes }

    public func remove(_ assetIDs: [String]) async -> RemovalResult {
        RemovalResult(removed: [], failed: assetIDs)
    }

    public func changes() -> AsyncStream<LibraryChange> { AsyncStream { $0.finish() } }
}
