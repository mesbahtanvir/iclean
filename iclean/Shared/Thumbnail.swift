import CleanupKit
import SwiftUI

/// Loads a preview already on the phone. Never downloads (FR-014).
struct Thumbnail: View {
    let assetID: String
    var maxPixels = 300
    var contentMode: ContentMode = .fill

    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    var body: some View {
        // The base shape sets the size; the image fills it and is cropped to it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: assetID) {
                image = await model.environment.library.preview(for: assetID, maxPixels: maxPixels).image
            }
    }
}
