#if os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// One photo in a grid on a Mac (spec 011 sections 6.5 and 6.15): the phone's verdict language,
    /// with a pointer and a keyboard instead of a finger.
    ///
    /// - At rest it is the photo alone. The check mark and the expand control appear when the pointer
    ///   is over it, when the keyboard is on it, and while it is selected (a selected photo always
    ///   shows its trash mark). Until they appear they cannot be clicked or tabbed to.
    /// - A click focuses the photo and nothing else. A click on the check mark toggles it, a
    ///   Command-click toggles it, a Shift-click selects the range from the last photo touched.
    /// - The keys are the grid's, not the cell's (`MacGridKeys`): one keyboard target for the whole
    ///   grid, so a grid of thousands is one Tab stop, and the photo the keyboard is on exists even
    ///   after its cell scrolled away. Space toggles, Return and a double-click open the viewer,
    ///   the arrow keys move (with Shift they extend a range), and Delete opens the Confirm sheet.
    ///   Nothing here confirms a removal.
    /// - A context menu replaces the long press, and every on-photo control has a tooltip.
    ///
    /// Only the little views that draw the ring and the two controls read where the keyboard is, so
    /// a key press redraws those and not the whole cell.
    struct MacItemCell: View {
        let assetID: String
        var isKeeper: Bool
        var confidence: Confidence = .normal
        /// The pixels the picture needs, from the real width of the cell (`GridMetrics`).
        var pixelSize: Int
        /// The group this photo is in, nil in a flat grid.
        var group: ResultGroup?
        let navigator: GridNavigator
        var onView: () -> Void

        @Environment(AppModel.self) private var model
        @Environment(ThumbnailPrefetcher.self) private var prefetcher
        @State private var hovering = false

        var body: some View {
            let item = model.results.items[assetID]
            let selected = model.isSelected(assetID)
            let favorite = item?.metadata.isFavorite == true
            let inAlbums = item?.metadata.albumNames.isEmpty == false
            let previewOnly = item?.analysisSource == .cloudPreview || confidence == .lower
            let showsKept = isKeeper && !selected
            let isVideo = item?.metadata.kind.isVideo == true
            Thumbnail(assetID: assetID, maxPixels: pixelSize)
                // Only the picture is darkened: the scrim sits under the marks and the chip.
                .overlay {
                    if selected { Color.black.opacity(0.28) }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .contentShape(Rectangle())
                // The clicks on the picture. They are on the picture alone, below the two buttons
                // that sit on it: a click on a button is the button's, so exactly one handler acts
                // (gestures on the whole cell also fire for a click on a button, and a Command-click
                // on the check mark would toggle twice). The double click is declared before the
                // single one, so it is the one that wins.
                .onTapGesture(count: 2) { onView() }
                .simultaneousGesture(TapGesture().onEnded { clicked() })
                .overlay(alignment: .topTrailing) {
                    MarkControl(
                        assetID: assetID, navigator: navigator, hovering: hovering,
                        selected: selected, isVideo: isVideo
                    ) {
                        clicked(onMark: true)
                    }
                }
                .overlay(alignment: .topLeading) {
                    ExpandControl(
                        assetID: assetID, navigator: navigator, hovering: hovering,
                        selected: selected
                    ) {
                        navigator.focus(assetID)
                        navigator.anchor = assetID
                        onView()
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // At most three parts in the one capsule; the album glyph is the one given up.
                    // Only a label: a click on it is a click on the picture below.
                    PhotoChip(
                        keeper: showsKept, favorite: favorite,
                        inAlbums: inAlbums && !(showsKept && favorite && previewOnly),
                        previewOnly: previewOnly
                    )
                    .padding(Space.xs)
                    .allowsHitTesting(false)
                }
                .overlay { FocusRing(assetID: assetID, navigator: navigator) }
                .calmAnimation(value: selected)
                .onHover { hovering = $0 }
                .contextMenu { menu(selected: selected, isVideo: isVideo) }
                .onAppear {
                    prefetcher.appeared(assetID)
                    navigator.appeared(assetID)
                }
                .onDisappear {
                    prefetcher.disappeared(assetID)
                    navigator.disappeared(assetID)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ItemCell.description(
                        item: item, isKeeper: isKeeper, confidence: confidence,
                        favorite: favorite, inAlbums: inAlbums)
                )
                .accessibilityValue(ReviewState.text(selected: selected))
                .accessibilityHint(
                    ReviewState.changeHint(isVideo: item?.metadata.kind.isVideo == true)
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("category.item.\(assetID)")
                // The VoiceOver press toggles; the click does not, so it has its own action.
                .accessibilityAction(.default) { model.toggle(assetID) }
                .accessibilityAction(named: Text("View full screen"), onView)
                .accessibilityAction(named: Text("Always Keep")) {
                    Task { await model.alwaysKeep(assetID) }
                }
                .modifier(RestOfGroupAction(group: group, model: model))
        }

        // MARK: Pointer

        /// A click: it focuses the photo and nothing else. With Command it toggles, with Shift it
        /// selects the range from the last photo touched (never a suggested keeper). A click on the
        /// check mark (`onMark`) toggles, and with Shift it is still the range.
        private func clicked(onMark: Bool = false) {
            navigator.focus(assetID)
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                model.setSelected(navigator.plan.range(from: navigator.anchor, to: assetID), true)
            } else if onMark || flags.contains(.command) {
                navigator.anchor = assetID
                model.toggle(assetID)
            } else {
                navigator.anchor = assetID
            }
        }

        // MARK: Context menu

        @ViewBuilder private func menu(selected: Bool, isVideo: Bool) -> some View {
            Button("View Larger", action: onView)
            Button("Always Keep") { Task { await model.alwaysKeep(assetID) } }
            Divider()
            if selected {
                if isVideo {
                    Button("Keep This Video") { model.toggle(assetID) }
                } else {
                    Button("Keep This Photo") { model.toggle(assetID) }
                }
            } else {
                Button("Select for Removal") { model.toggle(assetID) }
            }
            if let group, group.members.count > 1 {
                Button("Select the Rest of This Group") {
                    RestOfGroupAction.select(group, in: model)
                }
            }
        }
    }

    /// "Select the Rest of This Group" for VoiceOver and Switch Control, as the context menu has it,
    /// on the photos of a group of more than one.
    private struct RestOfGroupAction: ViewModifier {
        let group: ResultGroup?
        let model: AppModel

        @ViewBuilder func body(content: Content) -> some View {
            if let group, group.members.count > 1 {
                content.accessibilityAction(named: Text("Select the Rest of This Group")) {
                    Self.select(group, in: model)
                }
            } else {
                content
            }
        }

        /// The photos suggested to keep stay: this is "the rest", not "all".
        @MainActor static func select(_ group: ResultGroup, in model: AppModel) {
            model.setSelected(group.members.filter { !group.keepers.contains($0) }, true)
        }
    }

    // MARK: What reads the keyboard

    /// The keyboard focus: a 3 pt ring in the accent, drawn by hand because the system's own ring is
    /// a rectangle that ignores the rounded corners.
    private struct FocusRing: View {
        let assetID: String
        let navigator: GridNavigator

        var body: some View {
            RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .opacity(navigator.isFocused(assetID) ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    /// Whether a cell's controls are shown: under the pointer, on the keyboard's photo, or selected.
    /// Hidden, they are not just faded: they take no clicks, show no tooltip and are not a Tab stop,
    /// so nothing invisible can be pressed. A click where one is goes to the picture, which focuses
    /// it, and the controls are then there for the next.
    @MainActor private func showsControls(
        _ navigator: GridNavigator, _ assetID: String, hovering: Bool, selected: Bool
    ) -> Bool {
        hovering || selected || navigator.isFocused(assetID)
    }

    /// The check mark: a click on it toggles removal. 28 pt or more to hit, plain so macOS draws no
    /// bezel around it.
    private struct MarkControl: View {
        let assetID: String
        let navigator: GridNavigator
        let hovering: Bool
        let selected: Bool
        let isVideo: Bool
        let action: () -> Void

        var body: some View {
            let shown = showsControls(navigator, assetID, hovering: hovering, selected: selected)
            let help: LocalizedStringKey =
                selected
                ? (isVideo ? "Keep This Video" : "Keep This Photo") : "Select for Removal"
            Button(action: action) {
                SelectionMark(selected: selected)
                    .padding(Space.xs)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .padding(Space.xs)
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .focusable(false)
            .accessibilityHidden(true)
        }
    }

    /// Opens the viewer: a 24 pt glyph on a scrim, tucked into the corner, with a 36 pt hit area (a
    /// pointer needs less than a fingertip, and the picture is as small as 90 pt).
    private struct ExpandControl: View {
        let assetID: String
        let navigator: GridNavigator
        let hovering: Bool
        let selected: Bool
        let action: () -> Void

        @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

        var body: some View {
            let shown = showsControls(navigator, assetID, hovering: hovering, selected: selected)
            Button(action: action) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: size, height: size)
                    .onPhotoScrim(in: Circle())
                    .padding(Space.xs + 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("View full screen"))
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .focusable(false)
            .accessibilityHidden(true)
        }
    }
#endif
