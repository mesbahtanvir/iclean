import SwiftUI

/// The app's vocabulary of sizes, colours and motion (spec 009 section 4). Small on purpose: system
/// components and text styles do the rest, so Dynamic Type, Dark Mode and platform looks come free.

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    /// The side gutter and the inset of text.
    static let l: CGFloat = 16
    /// Between blocks.
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Gutter {
    /// Between photos in a grid.
    static var grid: CGFloat {
        #if os(macOS)
            4
        #else
            2
        #endif
    }
}

enum Radius {
    /// Thumbnails and video thumbnails.
    static let tile: CGFloat = 8
    /// Compare photos and callouts.
    static let card: CGFloat = 12
}

enum Layout {
    /// Home, Done and the Mac Overview: wider than this reads badly.
    static let readable: CGFloat = 560
    static let access: CGFloat = 480
    static let macSheet: CGFloat = 440
}

enum Typography {
    /// Supporting text and caveats. The Mac's footnote is 10 pt, which is too small to read.
    static var note: Font {
        #if os(macOS)
            .subheadline
        #else
            .footnote
        #endif
    }
}

extension View {
    /// Centres the content in a column no wider than `maxWidth`; on a phone it changes nothing.
    func readableColumn(_ maxWidth: CGFloat = Layout.readable) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity)
    }

    /// The only way animation enters the app: quick, no bounce, and none at all under Reduce Motion.
    func calmAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(CalmAnimation(value: value))
    }

    /// The hero figure: large, rounded, fixed-width digits; scales with Dynamic Type up to a cap.
    func heroFigureFont() -> some View { modifier(HeroFigureFont()) }

    /// A dark tint behind white content on a photo. Never a blur: a blur on every visible cell is
    /// costly to scroll.
    func onPhotoScrim<S: Shape>(in shape: S) -> some View {
        modifier(OnPhotoScrim(shape: shape))
    }
}

private struct CalmAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .snappy(duration: 0.25), value: value)
    }
}

private struct HeroFigureFont: ViewModifier {
    #if os(macOS)
        @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 40
    #else
        @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 48
    #endif

    func body(content: Content) -> some View {
        content
            .font(.system(size: min(size, 88), weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}

private struct OnPhotoScrim<S: Shape>: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: S

    func body(content: Content) -> some View {
        content.background(Color.black.opacity(contrast == .increased ? 0.7 : 0.55), in: shape)
    }
}
