import CleanupKit
import SwiftUI

/// Compare the photos in a group side by side and change the keeper (spec 009 6.7).
///
/// The title is the group's own name, a live summary line sits above the cards, and each card is
/// about 60% of the width so the next one peeks. The rows of a card are in a fixed order, so the
/// dates, the sizes and the Remove switches line up across cards. At accessibility sizes the cards
/// become a vertical list of full-width cards.
struct GroupDetailView: View {
    let groupID: String
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @State private var viewing: String?
    @State private var width: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 36
    /// A slot that holds the "Keep This Copy" button, which is 44 pt or more tall.
    @ScaledMetric(relativeTo: .body) private var buttonSlot: CGFloat = 50
    @ScaledMetric(relativeTo: .body) private var tallSlot: CGFloat = 60

    var body: some View {
        let group = model.results.category(category)?.groups.first { $0.id == groupID }
        // Something that always has the full size, so the width can be measured before there is
        // content: the pictures are asked for at the size of a card, which needs the width.
        ZStack {
            Color.clear
            if let group {
                if width > 0 { content(group) }
            } else if model.launchPhase != .ready || model.isBuildingResults {
                DelayedProgress()
                    .accessibilityIdentifier("group.loading")
            } else {
                ContentUnavailableView {
                    Label("Already Taken Care Of", systemImage: "checkmark.circle")
                } description: {
                    Text("These photos were removed or changed, so there is nothing to compare.")
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
        .navigationTitle(group.map(Self.title) ?? Text(verbatim: category.title))
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .photoViewer($viewing)
    }

    /// "3 copies", "5 similar shots": the name of this group, not of its category.
    private static func title(_ group: ResultGroup) -> Text {
        let count = group.members.count
        return group.type == .similarShots
            ? Text("^[\(count) similar shot](inflect: true)")
            : Text("^[\(count) copy](inflect: true)")
    }

    // MARK: Layout

    @ViewBuilder private func content(_ group: ResultGroup) -> some View {
        let ratio = aspectRatio(of: group)
        let stacked = typeSize.isAccessibilitySize
        // About 60% of the width, so the next card peeks: three of five columns with a gap
        // between them, inside the gutters. Computed here, not by `containerRelativeFrame`, which
        // gave the second card of a group a narrower frame than the first.
        let container = max(width - 2 * Space.l, 1)
        let cardWidth =
            stacked ? container : max((container - 4 * Space.m) / 5 * 3 + 2 * Space.m, 1)
        // The photo has a size of its own, not a share of whatever height is left: in a lazy row
        // a card taller than the first would otherwise squeeze its photo.
        let photoSize = CGSize(width: cardWidth, height: cardWidth / ratio)
        let pixels = GridMetrics.pixels(
            width: Double(cardWidth), minimum: Double(cardWidth), spacing: 0,
            scale: Double(displayScale), cap: 1024)
        // A favorite keeper has a second line; every card keeps the same slot height so the
        // Remove switches stay at one height.
        let hasButton = group.type != .similarShots
        let slotHeight =
            group.hasFavoriteKeeper(in: model.results) ? tallSlot : (hasButton ? buttonSlot : slot)
        if stacked {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    summary(group, inset: false)
                    ForEach(Array(group.members.enumerated()), id: \.element) { index, id in
                        card(
                            group, id: id, index: index, photo: photoSize, pixels: pixels,
                            slot: slotHeight)
                    }
                }
                .padding(Space.l)
            }
            .accessibilityIdentifier("group.compare")
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                summary(group, inset: true)
                ScrollView {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: Space.m) {
                                ForEach(Array(group.members.enumerated()), id: \.element) {
                                    index, id in
                                    card(
                                        group, id: id, index: index, photo: photoSize,
                                        pixels: pixels,
                                        slot: slotHeight
                                    )
                                    .frame(width: cardWidth)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .contentMargins(.horizontal, Space.l, for: .scrollContent)
                        .scrollTargetBehavior(.viewAligned)
                        .scrollIndicators(.hidden)
                        .accessibilityIdentifier("group.compare")
                        // A restored screen opens on the copy the person last touched.
                        .onAppear {
                            if let id = model.restoredFocus, group.members.contains(id) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The pinned lines above the cards.
    private func summary(_ group: ResultGroup, inset: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GroupSummaryLine(group: group)
            if group.type == .similarShots {
                Text("Turn off a photo’s Remove switch to keep it.")
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
            }
        }
        .padding(.horizontal, inset ? Space.l : 0)
        .padding(.top, inset ? Space.s : 0)
    }

    private func card(
        _ group: ResultGroup, id: String, index: Int, photo: CGSize, pixels: Int, slot: CGFloat
    ) -> some View {
        CompareCard(
            group: group, assetID: id, index: index, photoSize: photo, pixelSize: pixels,
            slotHeight: slot, onView: { viewing = id })
    }

    /// One shape for every photo of the group, so the rows line up: the keeper's own shape,
    /// kept within a range that never makes a card very tall or very flat.
    private func aspectRatio(of group: ResultGroup) -> CGFloat {
        let reference = group.members.first(where: group.keepers.contains) ?? group.members.first
        let own = reference.flatMap { model.results.items[$0]?.metadata.aspectRatio } ?? 0
        return (own > 0 ? CGFloat(own) : 4 / 3).clamped(to: 0.75...1.33)
    }
}

extension ResultGroup {
    /// Whether a keeper is a favorite, which gives its card a second line.
    fileprivate func hasFavoriteKeeper(in results: CleanupResults) -> Bool {
        keepers.contains { results.items[$0]?.metadata.isFavorite == true }
    }
}

/// "Keeping 1 · removing 2 · about 4.8 MB": what the switches below say, added up. A group has a
/// few members, so this is cheap, and only this line re-draws when a switch changes.
private struct GroupSummaryLine: View {
    let group: ResultGroup

    @Environment(AppModel.self) private var model

    var body: some View {
        let removing = group.members.filter { model.isSelected($0) }
        let keeping = group.members.count - removing.count
        let bytes = removing.reduce(Int64(0)) {
            $0 + (model.results.items[$1]?.effectiveByteSize ?? 0)
        }
        let estimate = removing.contains { model.results.items[$0]?.sizeIsEstimate ?? true }
        Group {
            if removing.isEmpty {
                Text("Keeping \(keeping) · removing \(removing.count)")
            } else {
                let size = Format.bytes(bytes, estimate: estimate)
                Text("Keeping \(keeping) · removing \(removing.count) · \(size)")
            }
        }
        .font(.subheadline)
        .contentTransition(.numericText())
        .calmAnimation(value: removing.count)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("group.summary")
    }
}

/// One copy: the photo, its facts, whether it is the keeper, and the switch that decides.
private struct CompareCard: View {
    let group: ResultGroup
    let assetID: String
    let index: Int
    let photoSize: CGSize
    let pixelSize: Int
    let slotHeight: CGFloat
    let onView: () -> Void

    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        let item = model.results.items[assetID]
        let selected = model.isSelected(assetID)
        let isKeeper = group.keepers.contains(assetID)
        VStack(alignment: .leading, spacing: Space.s) {
            photo(item, selected: selected)
            facts(item)
            status(item, isKeeper: isKeeper)
            removeSwitch(item, selected: selected)
            notes(isKeeper: isKeeper)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    // MARK: Rows, in a fixed order

    /// The photo in its real shape. A card marked for removal gets the same scrim and trash mark as
    /// the grid; the mark is decoration, the switch is the control. Tapping the photo looks at it.
    private func photo(_ item: CleanupKit.LibraryItem?, selected: Bool) -> some View {
        Button(action: onView) {
            Thumbnail(assetID: assetID, maxPixels: pixelSize)
                .overlay {
                    if selected { Color.black.opacity(0.28) }
                }
                .frame(width: photoSize.width, height: photoSize.height)
                .overlay(alignment: .topTrailing) {
                    SelectionMark(selected: selected)
                        .dynamicTypeSize(...DynamicTypeSize.xLarge)
                        .padding(Space.s)
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .calmAnimation(value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(item?.metadata.kind.spokenName ?? ItemKind.photo.spokenName) \(index + 1) of \(group.members.count)"
        )
        .accessibilityHint(Text("Opens it full screen"))
    }

    @ViewBuilder private func facts(_ item: CleanupKit.LibraryItem?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let date = item?.metadata.captureDate {
                Text(Format.capture(date))
                    .font(.subheadline.weight(.medium))
            } else {
                Text("No date")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.quietText)
            }
            if let item {
                Text(Format.facts(of: item))
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
            }
        }
    }

    /// The keeper says so; another copy of a duplicate can be made the keeper; a similar shot that
    /// is not the keeper leaves the slot empty.
    private func status(_ item: CleanupKit.LibraryItem?, isKeeper: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if isKeeper {
                Label {
                    Text("Suggested to keep")
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
                .font(.subheadline)
                if item?.metadata.isFavorite == true {
                    Text("Marked as a favorite")
                        .font(Typography.note)
                        .foregroundStyle(Palette.quietText)
                        .accessibilityIdentifier("group.keeperReason.\(assetID)")
                }
            } else if group.type == .duplicatePhotos || group.type == .duplicateVideos {
                Button("Keep This Copy") {
                    taps += 1
                    model.makeKeeper(assetID)
                }
                .buttonStyle(.bordered)
                .tint(Palette.accentText)
                // Large is the 44 pt hit area; the status slot below is tall enough to hold it.
                .controlSize(.large)
                .accessibilityIdentifier("group.makeKeeper")
            }
        }
        .frame(maxWidth: .infinity, minHeight: slotHeight, alignment: .topLeading)
    }

    /// ON means "selected for removal", not "good", so the switch is in the accent and never green.
    private func removeSwitch(_ item: CleanupKit.LibraryItem?, selected: Bool) -> some View {
        Toggle(
            isOn: Binding(
                get: { selected },
                set: { _ in
                    taps += 1
                    model.toggle(assetID)
                })
        ) {
            if group.type == .similarShots {
                Text("Remove this photo")
            } else {
                Text("Remove this copy")
            }
        }
        .font(.subheadline)
        #if os(macOS)
            .toggleStyle(.checkbox)
        #else
            .toggleStyle(.switch)
        #endif
        .tint(.accentColor)
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityLabel(switchLabel(item))
        .accessibilityIdentifier("group.toggle.\(assetID)")
    }

    /// "Remove copy 2 of 3, Nov 15, 2023".
    private func switchLabel(_ item: CleanupKit.LibraryItem?) -> String {
        let n = index + 1
        let count = group.members.count
        let base =
            group.type == .similarShots
            ? String(localized: "Remove photo \(n) of \(count)")
            : String(localized: "Remove copy \(n) of \(count)")
        guard let date = item?.metadata.captureDate else { return base }
        return base + ", " + date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Quiet notes about the date: why this copy's looks unreliable, or that the keeper's does not.
    private func notes(isKeeper: Bool) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(group.dateNotes[assetID] ?? [], id: \.self) { reason in
                QuietNote(Text(reason.explanation), systemImage: "info.circle")
                    .accessibilityIdentifier("group.dateNote.\(assetID).\(reason.rawValue)")
            }
            if isKeeper, !group.dateNotes.isEmpty, group.dateNotes[assetID] == nil {
                QuietNote("Its date looks reliable.", systemImage: "info.circle")
                    .accessibilityIdentifier("group.dateLikely.\(assetID)")
            }
        }
    }
}
