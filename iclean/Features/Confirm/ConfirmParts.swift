import CleanupKit
import SwiftUI

// The pieces of the Confirm sheet (spec 011 section 6.9). Each is small and reads only values it is
// handed, so the sheet's body stays short and nothing here reads the photo library.

/// What the sheet shows, worked out once when the plan arrives and never again in `body`.
struct LoadedPlan: Sendable {
    let plan: RemovalPlan
    let preview: RemovalPreview
    /// The photos for the strip: the largest ones, biggest first, at most `stripLimit`.
    let strip: [String]
    /// Photos, videos or items, from what is being removed.
    let noun: ItemNoun
    /// The categories present, in the app's fixed order.
    let categories: [CleanupCategory]

    static let stripLimit = 7

    /// One pass over the plan's ids (never a sort of all of them): with 30,000 photos selected this
    /// must not stall the sheet.
    nonisolated static func make(_ plan: RemovalPlan, remover: any Remover) -> LoadedPlan {
        let preview = remover.summary(for: plan.ids, in: plan.results)
        let categories = CleanupCategory.allCases.filter { preview.byCategory[$0] != nil }
        return LoadedPlan(
            plan: plan, preview: preview,
            strip: largest(stripLimit, of: plan.ids, in: plan.results),
            noun: ItemNoun(categories: categories), categories: categories)
    }

    /// The `limit` biggest photos of `ids` by size, biggest first; equal sizes by id so the strip does
    /// not change between two opens of the same sheet. Keeps a tiny sorted list, so it is O(n).
    nonisolated static func largest(
        _ limit: Int, of ids: Set<String>, in results: CleanupResults
    ) -> [String] {
        guard limit > 0 else { return [] }
        func before(_ a: (id: String, bytes: Int64), _ b: (id: String, bytes: Int64)) -> Bool {
            a.bytes != b.bytes ? a.bytes > b.bytes : a.id < b.id
        }
        var top: [(id: String, bytes: Int64)] = []
        top.reserveCapacity(limit + 1)
        for id in ids {
            let candidate = (id: id, bytes: results.items[id]?.effectiveByteSize ?? 0)
            if top.count == limit, let last = top.last, !before(candidate, last) { continue }
            var index = top.count
            while index > 0, before(candidate, top[index - 1]) { index -= 1 }
            top.insert(candidate, at: index)
            if top.count > limit { top.removeLast() }
        }
        return top.map(\.id)
    }
}

/// How much goes, and where it goes: the one answer of the sheet.
struct ConfirmHero: View {
    let bytes: Int64
    let count: Int
    let noun: ItemNoun

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // Always "about": what iclean measures on this device is not always what is freed
            // (iCloud Optimize Storage keeps small copies), so no exact claim is made.
            Text(Format.bytes(bytes, estimate: true))
                .heroFigureFont()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            caption
                .font(.callout)
                .foregroundStyle(Palette.quietText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Format.bytes(bytes, estimate: true)) \(captionString)"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("confirm.summary")
    }

    private var caption: Text {
        switch noun {
        case .photos: Text("\(count) photos move to Recently Deleted.")
        case .videos: Text("\(count) videos move to Recently Deleted.")
        case .items: Text("\(count) items move to Recently Deleted.")
        }
    }

    private var captionString: String {
        switch noun {
        case .photos: String(localized: "\(count) photos move to Recently Deleted.")
        case .videos: String(localized: "\(count) videos move to Recently Deleted.")
        case .items: String(localized: "\(count) items move to Recently Deleted.")
        }
    }
}

/// The reassurance that makes the button safe to press. Body size and primary colour: it is the
/// main message of the sheet, not a caveat.
struct ConfirmReassurance: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "arrow.uturn.backward")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Nothing is erased yet. For at least 30 days you can put them back from Photos.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("confirm.reassurance")
    }
}

/// The photos about to leave, as small tiles. Decoration for trust, so VoiceOver skips it and the
/// sheet hides it at accessibility sizes. Shows as many tiles as fit; the rest are a "+N" tile.
struct PhotoStrip: View {
    let ids: [String]
    let total: Int

    private let tile: CGFloat = 56
    private let gap: CGFloat = Space.xs

    var body: some View {
        GeometryReader { proxy in
            let capacity = max(1, Int((proxy.size.width + gap) / (tile + gap)))
            let fitsAll = total <= capacity && total <= ids.count
            let shown = fitsAll ? ids.count : min(ids.count, capacity - 1)
            let more = total - shown
            HStack(spacing: gap) {
                ForEach(ids.prefix(shown), id: \.self) { id in
                    Thumbnail(assetID: id, maxPixels: 192)
                        .frame(width: tile, height: tile)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                }
                if more > 0 {
                    Text(verbatim: "+\(more.formatted())")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Palette.quietText)
                        .frame(width: tile, height: tile)
                        .background(
                            .fill.secondary,
                            in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: tile)
        .accessibilityHidden(true)
        .accessibilityIdentifier("confirm.strip")
    }
}

/// One row per category, only when the removal spans two or more.
struct ConfirmCategoryRows: View {
    let categories: [CleanupCategory]
    let preview: RemovalPreview

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                if index > 0 { Divider().padding(.leading, Space.l) }
                if let total = preview.byCategory[category] {
                    row(category, total)
                }
            }
        }
        .confirmCard()
    }

    private func row(_ category: CleanupCategory, _ total: CategoryTotal) -> some View {
        let noun = ItemNoun(categories: [category])
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text("^[\(total.count) \(noun.singular)](inflect: true)")
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.m) }
            Text(Format.bytes(total.bytes, estimate: preview.isEstimate))
                .font(.body.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Every photo of some groups is selected, so nothing of those sets would stay. A calm card, not a
/// red alarm: the toggle is the gate that enables the button.
struct WholeGroupsCallout: View {
    let sets: Int
    @Binding var confirmed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Nothing will be kept from \(sets) sets")
                        .font(.headline)
                    Text(
                        "You’ve selected every photo in \(sets) sets, so none of them will stay in your library."
                    )
                    .font(.subheadline)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Remove them all anyway", isOn: $confirmed)
                .accessibilityIdentifier("confirm.removeAllWarning")
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .fill.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension View {
    /// A secondary-fill card for grouped rows on the sheet.
    fileprivate func confirmCard() -> some View {
        background(
            .fill.secondary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
