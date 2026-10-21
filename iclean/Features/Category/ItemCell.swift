import CleanupKit
import SwiftUI

/// One photo in a grid, and the whole verdict language of the app (spec 009 6.5):
///
/// - not selected: the picture at full strength with a white ring top-trailing;
/// - selected for removal: the picture alone is darkened by a 28% scrim and a neutral trash mark
///   sits top-trailing. The marks and the chip are drawn after the scrim, so they stay crisp;
/// - the keeper: a "Kept" pill bottom-leading, hidden while the keeper is itself selected.
///
/// A check means "stays", a trash mark means "goes". Nothing is red and the cell is never faded.
/// Tap toggles; a long press or the expand control opens the viewer.
struct ItemCell: View {
    let assetID: String
    var isKeeper: Bool
    var confidence: Confidence = .normal
    /// The pixels the picture needs, from the real width of the cell (`GridMetrics`).
    var pixelSize: Int
    var onView: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(ThumbnailPrefetcher.self) private var prefetcher
    /// Counts the person's own taps, so the haptic is theirs and not the model's.
    @State private var taps = 0

    var body: some View {
        let item = model.results.items[assetID]
        let selected = model.isSelected(assetID)
        let favorite = item?.metadata.isFavorite == true
        let inAlbums = item?.metadata.albumNames.isEmpty == false
        let previewOnly = item?.analysisSource == .cloudPreview || confidence == .lower
        let showsKept = isKeeper && !selected
        Thumbnail(assetID: assetID, maxPixels: pixelSize)
            // Only the picture is darkened: the scrim sits under the marks and the chip.
            .overlay {
                if selected { Color.black.opacity(0.28) }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                SelectionMark(selected: selected)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .padding(Space.xs + 2)
            }
            .overlay(alignment: .topLeading) {
                ExpandButton(action: onView)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
            }
            .overlay(alignment: .bottomLeading) {
                // At most three parts in the one capsule; the album glyph is the one given up.
                PhotoChip(
                    keeper: showsKept, favorite: favorite,
                    inAlbums: inAlbums && !(showsKept && favorite && previewOnly),
                    previewOnly: previewOnly
                )
                .padding(Space.xs)
            }
            .calmAnimation(value: selected)
            .contentShape(Rectangle())
            .onTapGesture {
                taps += 1
                model.toggle(assetID)
            }
            .onLongPressGesture(minimumDuration: 0.4) { onView() }
            .sensoryFeedback(.selection, trigger: taps)
            .onAppear { prefetcher.appeared(assetID) }
            .onDisappear { prefetcher.disappeared(assetID) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(description(item: item, favorite: favorite, inAlbums: inAlbums))
            .accessibilityValue(ReviewState.text(selected: selected))
            .accessibilityHint(ReviewState.changeHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("category.item.\(assetID)")
            .accessibilityAction(named: Text("View full screen"), onView)
            .accessibilityAction(named: Text("Always Keep")) {
                Task { await model.alwaysKeep(assetID) }
            }
    }

    /// A description only: what the photo is. Whether it goes is the value.
    private func description(item: CleanupKit.LibraryItem?, favorite: Bool, inAlbums: Bool)
        -> String
    {
        var parts: [String] = []
        var first = item?.metadata.kind.spokenName ?? ItemKind.photo.spokenName
        if let date = item?.metadata.captureDate { first += ", " + Format.capture(date) }
        parts.append(first + ".")
        if isKeeper { parts.append(String(localized: "Suggested to keep.")) }
        if favorite { parts.append(String(localized: "Favorite.")) }
        if inAlbums, let albums = item?.metadata.albumNames {
            let names = albums.joined(separator: ", ")
            parts.append(String(localized: "In albums: \(names)."))
        }
        if item?.analysisSource == .cloudPreview || confidence == .lower {
            parts.append(String(localized: "Checked from a preview only."))
        }
        return parts.joined(separator: " ")
    }
}

extension ReviewState {
    /// What VoiceOver says about how to change it: a double tap on a phone, the Space bar on a Mac.
    static var changeHint: Text {
        #if os(macOS)
            Text("Press the Space bar to change")
        #else
            Text("Double tap to change")
        #endif
    }
}

/// Opens the viewer. A 24 pt glyph on a scrim with a 44 pt hit area, tucked into the corner.
private struct ExpandButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: size, height: size)
                .onPhotoScrim(in: Circle())
                .padding(Space.xs + 2)
                .frame(width: 44, height: 44, alignment: .topLeading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
        #if os(macOS)
            .help(Text("View full screen"))
        #endif
    }
}
