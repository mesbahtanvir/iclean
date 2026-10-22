import CleanupKit
import SwiftUI

/// One row of Large Videos, the highest-regret list in the app, so the richest row (spec 009 6.6):
/// a 72 pt preview with its length, the size as the headline over "date · length", and a selection
/// mark that is visible on a plain row in light mode.
///
/// Tapping the row toggles it. Tapping the preview opens the viewer, so a person can look before
/// removing; that tap is not a nested button, and at accessibility sizes (where the row stacks and
/// the preview sits where the middle of the row is) it toggles like the rest of the row.
struct VideoRow: View {
    let assetID: String
    /// The pixels the 72 pt preview needs.
    var pixelSize: Int
    var onView: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(ThumbnailPrefetcher.self) private var prefetcher
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var taps = 0

    /// The width of the preview, and so where the text column starts.
    static let previewSide: CGFloat = 72

    var body: some View {
        let item = model.results.items[assetID]
        let selected = model.isSelected(assetID)
        let stacked = typeSize.isAccessibilitySize
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: Space.s) {
                    preview(item, stacked: true)
                    HStack(alignment: .center, spacing: Space.m) {
                        text(item)
                        Spacer(minLength: Space.s)
                        mark(selected)
                    }
                }
            } else {
                HStack(spacing: Space.m) {
                    preview(item, stacked: false)
                    text(item)
                    Spacer(minLength: Space.s)
                    mark(selected)
                }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .frame(minHeight: Self.previewSide)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .overlay(alignment: .bottom) {
            // A hairline inset to the text column.
            Divider().padding(.leading, stacked ? Space.l : Space.l + Self.previewSide + Space.m)
        }
        .calmAnimation(value: selected)
        .sensoryFeedback(.selection, trigger: taps)
        .onAppear { prefetcher.appeared(assetID) }
        .onDisappear { prefetcher.disappeared(assetID) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(item))
        .accessibilityValue(ReviewState.text(selected: selected))
        .accessibilityHint(Text("Changes whether this video is removed"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("category.item.\(assetID)")
        .accessibilityAction(named: Text("View full screen"), onView)
    }

    private func toggle() {
        taps += 1
        model.toggle(assetID)
    }

    private func preview(_ item: CleanupKit.LibraryItem?, stacked: Bool) -> some View {
        Thumbnail(assetID: assetID, maxPixels: pixelSize)
            .frame(width: Self.previewSide, height: Self.previewSide)
            .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if let length = item?.metadata.duration {
                    HStack(spacing: 2) {
                        Image(systemName: "play.fill")
                        Text(Format.duration(length)).monospacedDigit()
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .onPhotoScrim(in: Capsule())
                    .padding(Space.xs)
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { stacked ? toggle() : onView() }
    }

    private func text(_ item: CleanupKit.LibraryItem?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.bytes(item?.effectiveByteSize ?? 0, estimate: item?.sizeIsEstimate ?? true))
                .font(.headline)
            if let line = detail(item) {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Palette.quietText)
            }
        }
    }

    private func mark(_ selected: Bool) -> some View {
        SelectionMark(selected: selected, style: .onSurface)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .scaleEffect(28.0 / 24.0)
            .frame(width: 28, height: 28)
    }

    /// "Mar 3, 2024 · 5 min".
    private func detail(_ item: CleanupKit.LibraryItem?) -> String? {
        let date = item?.metadata.captureDate.map {
            $0.formatted(date: .abbreviated, time: .omitted)
        }
        let length = item?.metadata.duration.map(Format.durationShort)
        switch (date, length) {
        case (let date?, let length?): return String(localized: "\(date) · \(length)")
        case (let date?, nil): return date
        case (nil, let length?): return length
        case (nil, nil): return nil
        }
    }

    /// "Video, 5 minutes, 900 MB, Mar 3, 2024".
    private func spoken(_ item: CleanupKit.LibraryItem?) -> String {
        var parts = [ItemKind.video.spokenName]
        if let length = item?.metadata.duration { parts.append(Format.durationSpoken(length)) }
        parts.append(
            Format.bytes(item?.effectiveByteSize ?? 0, estimate: item?.sizeIsEstimate ?? true))
        if let date = item?.metadata.captureDate {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: ", ")
    }
}
