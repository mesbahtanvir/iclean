import CleanupKit
import SwiftUI

/// A picture of one item, already on the phone. Never downloads (FR-014).
///
/// The cache is read when the view is drawn, so a cell that scrolls back into view has its picture
/// on its first frame. Otherwise the picture arrives as a stream: a quick low-resolution one first
/// when that is all that is on the phone, then the final one. Leaving the screen cancels the work.
///
/// `maxPixels` is what the screen needs, taken from the real size of the cell (`GridMetrics`), so a
/// grid never asks for more pixels than it draws. A `.fill` thumbnail rests on a quiet slab while it
/// loads; a `.fit` one (the viewer) draws nothing of its own, so it sits on whatever is behind it.
struct Thumbnail: View {
    let assetID: String
    var maxPixels = 300
    var contentMode: ContentMode = .fill

    @Environment(AppModel.self) private var model
    @State private var loaded: ThumbnailImage?
    /// The stream ended without a picture: nothing usable on the phone (only in iCloud).
    @State private var unavailable = false

    private var fit: ThumbnailFit { contentMode == .fill ? .fill : .fit }

    /// What identifies the work: a new photo, or a new size after the cell was resized.
    private struct Work: Equatable {
        let assetID: String
        let maxPixels: Int
    }

    var body: some View {
        let cached = model.environment.thumbnails.picture(
            for: assetID, pixelSize: maxPixels, fit: fit)
        let shown = (loaded ?? cached)?.image
        // The base shape sets the size; the image fills it and is cropped to it.
        Rectangle()
            .fill(contentMode == .fill ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .overlay {
                if let shown {
                    Image(decorative: shown, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if contentMode == .fit && !unavailable {
                    ProgressView()
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: Work(assetID: assetID, maxPixels: maxPixels)) { await load() }
            // A grid keeps the state of cells that scrolled away: the picture stays in the cache
            // (bounded, and the cell reads it from there on its first frame when it comes back),
            // not in thousands of cells.
            .onDisappear { loaded = nil }
    }

    private func load() async {
        let cache = model.environment.thumbnails
        unavailable = false
        if cache.picture(for: assetID, pixelSize: maxPixels, fit: fit)?.isFinal == true { return }
        for await picture in model.environment.library.thumbnails(
            for: assetID, pixelSize: maxPixels, fit: fit)
        {
            cache.store(picture, for: assetID, pixelSize: maxPixels, fit: fit)
            loaded = picture
        }
        if loaded == nil, cache.picture(for: assetID, pixelSize: maxPixels, fit: fit) == nil {
            unavailable = true
        }
    }
}
