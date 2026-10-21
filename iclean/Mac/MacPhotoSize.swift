#if os(macOS)
    import SwiftUI

    /// How large the photos are in a category's grid: the one preference iclean keeps for the Mac
    /// (spec 009 section 6.15). The number is the smallest width a photo may have, so the grid fits as
    /// many columns as that allows.
    enum PhotoSize {
        static let key = "gridCellSize"
        static let range: ClosedRange<Double> = 90...260
        static let standard: Double = 150

        /// A stored value held to the slider's range, so a stray one cannot make a useless grid.
        static func clamped(_ value: Double) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    /// The photo-size slider in the toolbar of a category: a small photo, the slider, a large photo.
    struct PhotoSizeSlider: View {
        @AppStorage(PhotoSize.key) private var size = PhotoSize.standard

        var body: some View {
            HStack(spacing: Space.xs) {
                Image(systemName: "photo")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: $size, in: PhotoSize.range)
                    .frame(width: 110)
                    .controlSize(.small)
                    .accessibilityLabel("Photo size")
                    .accessibilityIdentifier("category.photoSize")
                Image(systemName: "photo")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .help("Photo size")
        }
    }
#endif
