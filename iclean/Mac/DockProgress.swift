#if os(macOS)
    import AppKit

    /// A thin accent bar over the app's icon in the Dock while a scan runs, instead of a red number
    /// (spec 009 section 6.15; the design brief allows no red badges). Dimmed while the scan is
    /// paused, and gone when it ends.
    ///
    /// Drawn with AppKit and not a SwiftUI view: a Dock tile's content view has no window, and a plain
    /// `draw(_:)` is the one thing that is certain to render there. Once a content view is set the Dock
    /// shows only that view, so it draws the icon itself.
    @MainActor
    final class DockProgress {
        static let shared = DockProgress()

        private let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        private var isShowing = false

        /// Shows the bar at `fraction` (0 to 1). Cheap enough to call once a second.
        func show(fraction: Double, paused: Bool) {
            let tile = NSApplication.shared.dockTile
            view.fraction = min(max(fraction, 0), 1)
            view.paused = paused
            let size = tile.size
            view.frame = NSRect(
                origin: .zero, size: size.width > 0 ? size : NSSize(width: 128, height: 128))
            tile.contentView = view
            isShowing = true
            tile.display()
        }

        /// Puts the plain icon back.
        func clear() {
            guard isShowing else { return }
            isShowing = false
            let tile = NSApplication.shared.dockTile
            tile.contentView = nil
            tile.display()
        }
    }

    /// The icon with a progress bar along its lower edge.
    final class DockProgressView: NSView {
        var fraction: Double = 0 { didSet { needsDisplay = true } }
        var paused = false { didSet { needsDisplay = true } }

        override func draw(_ dirtyRect: NSRect) {
            let icon = NSApplication.shared.applicationIconImage
            icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

            // The bar sits inside the icon's artwork, which has a margin of about a tenth.
            let width = bounds.width * 0.62
            let height = max(bounds.height * 0.06, 6)
            let track = NSRect(
                x: bounds.midX - width / 2, y: bounds.height * 0.17, width: width, height: height)
            let radius = height / 2

            NSColor.black.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

            let accent = NSColor(named: NSColor.Name("AccentColor")) ?? .controlAccentColor
            (paused ? NSColor.white.withAlphaComponent(0.55) : accent).setFill()
            var filled = track
            filled.size.width = max(track.width * fraction, height)
            NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()

            NSColor.white.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
            outline.lineWidth = 0.5
            outline.stroke()
        }
    }
#endif
