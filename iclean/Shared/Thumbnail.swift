import CleanupKit
import SwiftUI

/// A picture of one item, already on the phone. Never downloads (FR-014).
///
/// The cache is read when the view is drawn, so a cell that scrolls back into view has its picture
/// on its first frame. Otherwise the picture arrives as a stream: a quick low-resolution one first
/// when that is all that is on the phone, then the final one. Leaving the screen cancels the work.
struct Thumbnail: View {
    let assetID: String
    var maxPixels = 300
    var contentMode: ContentMode = .fill

    @Environment(AppModel.self) private var model
    @State private var loaded: ThumbnailImage?

    private var fit: ThumbnailFit { contentMode == .fill ? .fill : .fit }

    var body: some View {
        let cached = model.environment.thumbnails.picture(
            for: assetID, pixelSize: maxPixels, fit: fit)
        let shown = (loaded ?? cached)?.image
        // The base shape sets the size; the image fills it and is cropped to it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: assetID) { await load() }
    }

    private func load() async {
        let cache = model.environment.thumbnails
        if cache.picture(for: assetID, pixelSize: maxPixels, fit: fit)?.isFinal == true { return }
        for await picture in model.environment.library.thumbnails(
            for: assetID, pixelSize: maxPixels, fit: fit)
        {
            cache.store(picture, for: assetID, pixelSize: maxPixels, fit: fit)
            loaded = picture
        }
    }
}
