import CleanupKit
import SwiftUI

// The few views iclean draws itself (spec 009 section 4.4). Everything else is a system component.
//
// Buttons: the one next step is `.borderedProminent` at `.large` (a capsule); a secondary action is
// `.bordered`; a quiet one is `.borderless`. A disabled primary becomes `.bordered`, never a faded
// slab. Because the styles are different types, switch with if/else in a @ViewBuilder, not a ternary.
// Every Button inside a List or Form row gets an explicit `.borderless` or `.plain` style, or macOS
// draws a bezel around it.

/// The answer a screen exists to give: a small label, one large figure, a line of context.
struct HeroFigure: View {
    let overline: String
    let value: String
    let caption: String
    /// What VoiceOver says for the value, when it reads better than the figure ("36 megabytes").
    var spokenValue: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(overline)
                .font(.headline)
                .foregroundStyle(Palette.quietText)
            Text(value)
                .heroFigureFont()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                .calmAnimation(value: value)
            Text(caption)
                .font(.callout)
                .foregroundStyle(Palette.quietText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(overline) \(spokenValue ?? value) \(caption)"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Icon in secondary, title in primary: the icon is a hint, the words are the content.
struct QuietLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title
        }
    }
}

extension LabelStyle where Self == QuietLabelStyle {
    static var quiet: QuietLabelStyle { QuietLabelStyle() }
}

/// A caveat or a notice: small, secondary, no card, no fill. The only notice view in the app.
struct QuietNote: View {
    let text: Text
    let systemImage: String

    init(_ text: Text, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    init(_ key: LocalizedStringKey, systemImage: String) {
        self.init(Text(key), systemImage: systemImage)
    }

    var body: some View {
        Label {
            text
                .font(Typography.note)
                .foregroundStyle(Palette.quietText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(Typography.note)
                .foregroundStyle(.secondary)
        }
    }
}

/// Whether a photo is going to be removed. A check means "stays" or "done" everywhere in the app; a
/// trash mark means "goes". Shape and words carry the meaning, never colour alone, and red is not
/// used for it: removal is recoverable for at least 30 days.
struct SelectionMark: View {
    enum Style {
        /// On a photo: a ring over a darkened disc, so it shows on any picture.
        case overPhoto
        /// On a plain row.
        case onSurface
    }

    let selected: Bool
    var style: Style = .overPhoto

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if selected {
                Image(systemName: "trash.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(glyphColor, discColor)
                    .font(.system(size: size))
            } else {
                Circle()
                    .strokeBorder(ringColor, lineWidth: ringWidth)
                    .background(
                        Circle().fill(style == .overPhoto ? Color.black.opacity(0.28) : .clear)
                    )
                    .frame(width: size, height: size)
                    .shadow(color: style == .overPhoto ? .black.opacity(0.35) : .clear, radius: 1.5)
            }
        }
        .frame(width: size, height: size)
        // A mark must not grow into the photo it sits on.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityHidden(true)
    }

    private var ringWidth: CGFloat {
        contrast == .increased ? 3 : (style == .overPhoto ? 2 : 1.5)
    }

    private var ringColor: Color {
        style == .overPhoto ? .white : .secondary
    }

    private var glyphColor: Color {
        style == .overPhoto ? .white : Color.platformBackground
    }

    private var discColor: Color {
        style == .overPhoto
            ? Color.black.opacity(contrast == .increased ? 0.8 : 0.6) : Color.primary.opacity(0.85)
    }
}

/// One small capsule on a photo that says what is notable about it: kept, a favorite, in an album,
/// checked from a preview only. At most one capsule per photo, so a grid stays calm.
struct PhotoChip: View {
    var keeper = false
    var favorite = false
    var inAlbums = false
    var previewOnly = false

    var isEmpty: Bool { !(keeper || favorite || inAlbums || previewOnly) }

    var body: some View {
        if !isEmpty {
            HStack(spacing: Space.xs) {
                if keeper {
                    Label("Kept", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("category.keeperBadge")
                }
                if favorite {
                    Image(systemName: "heart.fill")
                }
                if inAlbums {
                    Image(systemName: "rectangle.stack")
                        .accessibilityIdentifier("category.albumBadge")
                }
                if previewOnly {
                    // Not an iCloud glyph: that would suggest a download, and iclean never downloads.
                    Image(systemName: "photo.badge.exclamationmark")
                        .accessibilityIdentifier("category.previewOnlyBadge")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .onPhotoScrim(in: Capsule())
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
        }
    }
}

/// Nothing for a moment, then a spinner: a quick load never flashes one. The one loading idiom.
struct DelayedProgress: View {
    var caption: LocalizedStringKey?
    var delay: Duration = .milliseconds(300)

    @State private var visible = false

    var body: some View {
        VStack(spacing: Space.m) {
            if visible {
                ProgressView()
                if let caption {
                    Text(caption)
                        .font(Typography.note)
                        .foregroundStyle(Palette.quietText)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .task {
            try? await Task.sleep(for: delay)
            visible = true
        }
    }
}

extension View {
    /// A bar pinned to the bottom edge. The inset is always applied and only the content comes and
    /// goes, so the list underneath keeps its identity and scroll position when the bar appears.
    func pinnedBar<Bar: View>(isPresented: Bool, @ViewBuilder content: () -> Bar) -> some View {
        modifier(PinnedBar(isPresented: isPresented, bar: content()))
    }
}

private struct PinnedBar<Bar: View>: ViewModifier {
    let isPresented: Bool
    let bar: Bar

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if isPresented {
                bar
                    .padding(.horizontal, Space.l)
                    .padding(.vertical, Space.s)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .transition(.opacity)
            }
        }
    }
}

extension Color {
    /// The plain background of a screen, on either platform.
    static var platformBackground: Color {
        #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }
}

/// "photos", "videos" or "items", from what the selection is made of.
enum ItemNoun {
    case photos, videos, items

    init(categories: some Collection<CleanupCategory>) {
        let videos = categories.filter { $0 == .largeVideos || $0 == .duplicateVideos }.count
        if categories.isEmpty {
            self = .photos
        } else if videos == categories.count {
            self = .videos
        } else if videos == 0 {
            self = .photos
        } else {
            self = .items
        }
    }

    /// For `Text("^[\(count) \(noun.singular)](inflect: true)")`: the English noun the system pluralises.
    var singular: String {
        switch self {
        case .photos: String(localized: "photo", comment: "One photo; the system makes the plural")
        case .videos: String(localized: "video", comment: "One video; the system makes the plural")
        case .items: String(localized: "item", comment: "One item; the system makes the plural")
        }
    }
}
