import SwiftUI

// Liquid Glass (spec 013). iOS 26 and macOS 26 draw bars, sheets and toolbars as glass by
// themselves; these are the few places where the app picks a style of its own. Earlier systems get
// the standard look spec 012 describes, so nothing here changes what a button does, only how the
// system draws it.
//
// Nothing is glass over a photo: a blur on every visible cell is costly to scroll (spec 012 4.2),
// so the marks and chips on a photo keep their scrim.

extension View {
    /// The one filled control on a screen: glass tinted with the accent on iOS 26 and macOS 26, the
    /// standard prominent button before. Used together with `actionShape(pinned:)`, which sets the
    /// shape and caps the text of a pinned button.
    @ViewBuilder func prominentButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    /// A secondary action, and a switched-off primary: clear glass on iOS 26 and macOS 26, the
    /// standard bordered button before. The label carries its own colour (`Palette.accentText`).
    @ViewBuilder func secondaryButtonStyle() -> some View {
        if #available(iOS 26, macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
