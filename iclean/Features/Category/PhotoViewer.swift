import AVFoundation
import AVKit
import CleanupKit
import SwiftUI

extension View {
    /// Presents the viewer for the photo whose id is bound: full screen on a phone, a sheet on a
    /// Mac (there is no full-screen cover there).
    func photoViewer(_ assetID: Binding<String?>) -> some View {
        let item = Binding<ViewedItem?>(
            get: { assetID.wrappedValue.map(ViewedItem.init) },
            set: { assetID.wrappedValue = $0?.id }
        )
        #if os(macOS)
            return sheet(item: item) { PhotoViewer(assetID: $0.id) }
        #else
            return fullScreenCover(item: item) { PhotoViewer(assetID: $0.id) }
        #endif
    }
}

private struct ViewedItem: Identifiable {
    let id: String
}

/// Full-screen view of one item (spec 009 6.8): one black stage, a state line and two labelled
/// buttons at the bottom, real zoom for a photo, and playback for a video that is on the device.
struct PhotoViewer: View {
    let assetID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the photo is zoomed and where it is moved to. The base values are kept between
    /// gestures, so a second pinch starts from where the first one ended.
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var stage: CGSize = .zero
    @State private var taps = 0
    /// A video on the device, ready to play (nil until known, and for one that is only in iCloud).
    @State private var playable: PlayableVideo?
    @State private var player: AVPlayer?

    private static let maxScale: CGFloat = 6
    private static let doubleTapScale: CGFloat = 2.5

    var body: some View {
        let item = model.results.items[assetID]
        NavigationStack {
            stageView(item)
                .safeAreaInset(edge: .bottom, spacing: 0) { controls(item) }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .principal) { title(item) }
                }
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.black, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                #endif
        }
        .preferredColorScheme(.dark)
        #if os(macOS)
            // A sheet on the Mac has no size of its own.
            .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        #endif
        .task { await prepareVideo(item) }
        .onChange(of: assetID) { resetZoom() }
        .onDisappear { player?.pause() }
    }

    private var isVideo: Bool { model.results.items[assetID]?.metadata.kind.isVideo == true }

    /// The pixels asked for: the picture of a photo filling a big screen.
    private var pixelRequest: Int {
        #if os(macOS)
            3072
        #else
            2048
        #endif
    }

    // MARK: The stage

    private func stageView(_ item: CleanupKit.LibraryItem?) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
            } else if isVideo {
                // The still frame; a play control appears when the video is on the device.
                still
                    .overlay { if playable != nil { playButton } }
            } else {
                zoomable(still, item)
            }
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: {
            stage = $0
        }
    }

    private var still: some View {
        Thumbnail(assetID: assetID, maxPixels: pixelRequest, contentMode: .fit)
    }

    private var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.title.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .onPhotoScrim(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Play"))
        .accessibilityIdentifier("viewer.play")
    }

    // MARK: Zoom

    private func zoomable(_ picture: some View, _ item: CleanupKit.LibraryItem?) -> some View {
        picture
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        scale = (baseScale * value.magnification).clamped(to: 1...Self.maxScale)
                        offset = limited(baseOffset, item: item, scale: scale)
                    }
                    .onEnded { value in
                        baseScale = (baseScale * value.magnification).clamped(to: 1...Self.maxScale)
                        if baseScale < 1.02 {
                            resetZoom()
                        } else {
                            scale = baseScale
                            offset = limited(offset, item: item, scale: scale)
                            baseOffset = offset
                        }
                    }
            )
            // The photo moves only while it is zoomed in; at 1x a drag is not for the photo.
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        let moved = CGSize(
                            width: baseOffset.width + value.translation.width,
                            height: baseOffset.height + value.translation.height)
                        offset = limited(moved, item: item, scale: scale)
                    }
                    .onEnded { _ in baseOffset = offset },
                including: scale > 1 ? .all : .none
            )
            .onTapGesture(count: 2) {
                setZoom(baseScale > 1 ? 1 : Self.doubleTapScale, item: item)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(ItemKind.photo.spokenName))
            // The adjustable trait below tells how to change it, in the platform's own words.
            .accessibilityValue(Text("Zoom \(Int((scale * 100).rounded())) percent"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: setZoom(baseScale * 1.5, item: item)
                case .decrement: setZoom(baseScale / 1.5, item: item)
                @unknown default: break
                }
            }
    }

    private func setZoom(_ target: CGFloat, item: CleanupKit.LibraryItem?) {
        let value = target.clamped(to: 1...Self.maxScale)
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            baseScale = value < 1.02 ? 1 : value
            scale = baseScale
            offset = baseScale == 1 ? .zero : limited(offset, item: item, scale: baseScale)
            baseOffset = offset
        }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }

    /// Keeps the photo from being dragged past its own edges: it can move only as far as the part
    /// of it that sticks out of the stage.
    private func limited(_ moved: CGSize, item: CleanupKit.LibraryItem?, scale: CGFloat) -> CGSize {
        let aspect = (item?.metadata.aspectRatio).flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 4 / 3
        guard stage.width > 0, stage.height > 0 else { return .zero }
        // The size of the photo at 1x: fitted into the stage.
        let fitted =
            aspect > stage.width / stage.height
            ? CGSize(width: stage.width, height: stage.width / aspect)
            : CGSize(width: stage.height * aspect, height: stage.height)
        let maxX = max(0, (fitted.width * scale - stage.width) / 2)
        let maxY = max(0, (fitted.height * scale - stage.height) / 2)
        return CGSize(
            width: moved.width.clamped(to: -maxX...maxX),
            height: moved.height.clamped(to: -maxY...maxY))
    }

    // MARK: Video

    private func prepareVideo(_ item: CleanupKit.LibraryItem?) async {
        guard item?.metadata.kind.isVideo == true else { return }
        playable = await model.environment.library.playerItem(for: assetID)
    }

    private func play() {
        guard let playable else { return }
        #if os(iOS)
            // Videos play with their sound, whatever the silent switch says.
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let player = AVPlayer(playerItem: playable.item)
        self.player = player
        player.play()
    }

    // MARK: Bars

    /// The capture date over "4,032 × 3,024 · 3.2 MB".
    private func title(_ item: CleanupKit.LibraryItem?) -> some View {
        VStack(spacing: 0) {
            if let date = item?.metadata.captureDate {
                Text(Format.capture(date))
                    .font(.subheadline.weight(.semibold))
            }
            if let item {
                Text(Format.facts(of: item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func controls(_ item: CleanupKit.LibraryItem?) -> some View {
        let selected = model.isSelected(assetID)
        let video = item?.metadata.kind.isVideo == true
        return VStack(spacing: Space.m) {
            Text(ReviewState.text(selected: selected))
                .font(Typography.note)
                .accessibilityIdentifier("viewer.state")
            // Side by side while each half is wide enough for its words, stacked when not.
            ViewThatFits(in: .horizontal) {
                EqualWidthRow(spacing: Space.m) {
                    toggleButton(selected: selected, video: video)
                    alwaysKeepButton
                }
                VStack(spacing: Space.s) {
                    toggleButton(selected: selected, video: video)
                    alwaysKeepButton
                }
            }
            Group {
                if video {
                    Text("Never suggest this video again.")
                } else {
                    Text("Never suggest this photo again.")
                }
            }
            .font(Typography.note)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity)
        .background(.black)
        // Chrome is monochrome here: the photo is the only colour on the stage.
        .tint(.white)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func toggleButton(selected: Bool, video: Bool) -> some View {
        Button {
            taps += 1
            model.toggle(assetID)
        } label: {
            if selected {
                if video {
                    Label("Keep This Video", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Keep This Photo", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Label("Select for Removal", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("viewer.toggleSelect")
    }

    private var alwaysKeepButton: some View {
        Button {
            Task {
                await model.alwaysKeep(assetID)
                dismiss()
            }
        } label: {
            Label("Always Keep", systemImage: "checkmark.shield")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("viewer.alwaysKeep")
    }
}

/// Lays its children in one row of equal widths. Its ideal width is the widest child twice over, so
/// `ViewThatFits` falls back to the stacked layout when two equal halves would make a label wrap.
private struct EqualWidthRow: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ())
        -> CGSize
    {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let ideals = subviews.map { $0.sizeThatFits(.unspecified) }
        guard let available = proposal.width else {
            let widest = ideals.map(\.width).max() ?? 0
            return CGSize(
                width: widest * CGFloat(subviews.count) + gaps,
                height: ideals.map(\.height).max() ?? 0)
        }
        let each = max(0, (available - gaps) / CGFloat(subviews.count))
        let height =
            subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: nil)).height }
            .max() ?? 0
        return CGSize(width: available, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let each = max(0, (bounds.width - gaps) / CGFloat(subviews.count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                proposal: ProposedViewSize(width: each, height: bounds.height))
            x += each + spacing
        }
    }
}
