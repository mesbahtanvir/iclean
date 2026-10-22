#if os(macOS)
    import Observation
    import SwiftUI

    /// How large the photos are in a category's grid: the one preference iclean keeps for the Mac
    /// (spec 012 section 6.15). The number is the smallest width a photo may have, so the grid fits as
    /// many columns as that allows.
    enum PhotoSize {
        static let key = "gridCellSize"
        static let range: ClosedRange<Double> = 90...260
        static let standard: Double = 150
        /// The slider moves in these steps: the grid changes at most 17 times from end to end, and
        /// the arrow keys and VoiceOver move it by something a person can see.
        static let step: Double = 10

        /// A stored value held to the slider's range, so a stray one cannot make a useless grid.
        static func clamped(_ value: Double) -> Double {
            min(max(value, range.lowerBound), range.upperBound)
        }
    }

    /// The size under the slider's thumb while it is down, nil otherwise. The grid lays itself out
    /// at it, so it follows the thumb, but the pictures it asks for, and the stored setting, wait
    /// for the thumb to be let go.
    @MainActor @Observable
    final class PhotoSizeDrag {
        static let shared = PhotoSizeDrag()
        var size: Double?
    }

    /// The photo-size slider in the toolbar of a category: a small photo, the slider, a large photo.
    ///
    /// It keeps its value to itself while it is dragged and writes the setting when the thumb is let
    /// go (or at once for a key press or VoiceOver, which have no drag): a write on every mouse
    /// event would reach every view that reads the setting.
    struct PhotoSizeSlider: View {
        @AppStorage(PhotoSize.key) private var stored = PhotoSize.standard
        @State private var value: Double
        @State private var dragging = false

        private let drag = PhotoSizeDrag.shared

        init() {
            let saved = UserDefaults.standard.object(forKey: PhotoSize.key) as? Double
            _value = State(initialValue: PhotoSize.clamped(saved ?? PhotoSize.standard))
        }

        var body: some View {
            HStack(spacing: Space.xs) {
                Image(systemName: "photo")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(
                    value: $value, in: PhotoSize.range, step: PhotoSize.step,
                    onEditingChanged: { editing in
                        dragging = editing
                        if editing { drag.size = value } else { commit() }
                    }
                )
                .frame(width: 80)
                .controlSize(.small)
                .accessibilityLabel("Photo size")
                .accessibilityValue(Text("\(Int(value)) points"))
                .accessibilityIdentifier("category.photoSize")
                Image(systemName: "photo")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .help("Photo size")
            .onChange(of: value) { _, new in
                // A drag shows the size as it goes; anything else (keys, VoiceOver) is settled.
                if dragging { drag.size = new } else { commit() }
            }
            // The setting changed somewhere else.
            .onChange(of: stored) { _, new in
                if !dragging { value = PhotoSize.clamped(new) }
            }
            // The thumb can be gone before it is let go (another category is chosen).
            .onDisappear { drag.size = nil }
        }

        private func commit() {
            drag.size = nil
            if stored != value { stored = value }
        }
    }
#endif
