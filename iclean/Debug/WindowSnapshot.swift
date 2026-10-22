#if DEBUG && os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// Debug only. Lets a Mac screen be looked at without Screen Recording permission (macOS blocks
    /// capture from outside the app): the app saves its own windows as PNG files and quits.
    ///
    /// - `-SnapshotTo <file.png>`: save and quit. The file is the main window with every sheet that
    ///   is up drawn on it where it sits. Each sheet also goes to `<file>-sheet<N>.png`, and every
    ///   other visible window (Settings, Help) to `<file>-window<N>.png`.
    /// - `-SnapshotAfter <seconds>`: wait before saving (default 5).
    /// - `-WindowSize <width>x<height>`: size the window first.
    /// - `-OpenRoute category:<name>` or `group:<name>`: open that screen, through the same path as a
    ///   restored review, so the sidebar follows (needs results: use with `-AutoScan`).
    /// - `-SelectSidebar overview|<category>`: select that sidebar item (`-ShowScreen overview` too).
    /// - `-OpenSheet confirm|viewer`: present the Confirm sheet (for the selected category, or for
    ///   everything on the Overview) or the viewer (on the first photo of the selected category).
    /// - `-ShowScreen settings|saved|recent`: show that iPhone-style screen alone in the window.
    /// - `-ShowScreen settingsGeneral|settingsData|help`: show a tab of the Mac Settings window, or
    ///   the "How Removal Works" window, alone in the window (they are separate scenes otherwise).
    @MainActor
    enum WindowSnapshot {
        static func value(_ flag: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        /// A screen to show alone, for the screens that are not reached by a route.
        static var screenOverride: String? { value("-ShowScreen") }

        /// The sidebar item to select: "overview" or a category's name.
        static var requestedSidebar: String? {
            value("-SelectSidebar") ?? (screenOverride == "overview" ? "overview" : nil)
        }

        /// The sheet to present: "confirm" or "viewer".
        static var requestedSheet: String? { value("-OpenSheet") }

        private static func say(_ message: String) {
            print("[snapshot] \(message)")
            fflush(stdout)
        }

        static func runIfRequested(model: AppModel) async {
            say("requested: \(value("-SnapshotTo") ?? "no")")
            if let size = value("-WindowSize") { await resize(size) }
            if let route = value("-OpenRoute") { await open(route, in: model) }
            guard let path = value("-SnapshotTo") else { return }
            let delay = value("-SnapshotAfter").flatMap(Double.init) ?? 5
            try? await Task.sleep(for: .seconds(delay))
            say(
                "saving after \(delay) s; windows: \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible) sheets=\($0.sheets.count)" })"
            )
            save(to: path)
            say("saved, quitting")
            NSApp.terminate(nil)
        }

        private static func window() async -> NSWindow? {
            for _ in 0..<60 {
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) {
                    return w
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        private static func resize(_ size: String) async {
            let parts = size.split(separator: "x").compactMap { Double($0) }
            guard parts.count == 2, let w = await window() else { return }
            w.setContentSize(NSSize(width: parts[0], height: parts[1]))
            w.center()
        }

        private static func open(_ spec: String, in model: AppModel) async {
            let parts = spec.split(separator: ":").map(String.init)
            guard parts.count == 2, let category = CleanupCategory(rawValue: parts[1]) else {
                return
            }
            for _ in 0..<300 {
                if model.results.category(category) != nil { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let result = model.results.category(category) else { return }
            var path: [Route] = [.category(category)]
            if parts[0] == "group", let group = result.groups.first(where: { $0.type != .single }) {
                path.append(.group(category, containing: group))
            }
            model.restoredRoute = RestoredRoute(path: path)
        }

        // MARK: Saving

        /// Every visible window: the main one with its sheets drawn on it, then each sheet and each
        /// other window on its own.
        private static func save(to path: String) {
            let url = URL(fileURLWithPath: path)
            let visible = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
            guard
                let main = visible.first(where: {
                    $0.sheetParent == nil && $0.styleMask.contains(.titled)
                }) ?? visible.first,
                let mainImage = image(of: main)
            else {
                say("no window or bitmap")
                return
            }

            let sheets = main.sheets.filter { $0.isVisible && $0.contentView != nil }
            var layers: [(NSBitmapImageRep, NSRect)] = [
                (mainImage, NSRect(origin: .zero, size: main.frame.size))
            ]
            for (index, sheet) in sheets.enumerated() {
                guard let sheetImage = image(of: sheet) else { continue }
                // Window frames are in screen coordinates (origin at the bottom left), so the offset
                // from the main window is also where the sheet goes in the picture.
                let origin = NSPoint(
                    x: sheet.frame.minX - main.frame.minX, y: sheet.frame.minY - main.frame.minY)
                layers.append((sheetImage, NSRect(origin: origin, size: sheet.frame.size)))
                write(sheetImage, to: sibling(of: url, suffix: "-sheet\(index + 1)"))
            }
            if let combined = composite(layers, size: main.frame.size) {
                write(combined, to: url)
            }

            let others = visible.filter { $0 !== main && !sheets.contains($0) }
            for (index, other) in others.enumerated() {
                guard let picture = image(of: other) else { continue }
                write(picture, to: sibling(of: url, suffix: "-window\(index + 1)"))
            }
        }

        /// One window as it draws itself, title bar and toolbar included. No screen capture: the
        /// view hierarchy is asked to draw into a bitmap, so no permission is needed.
        private static func image(of window: NSWindow) -> NSBitmapImageRep? {
            // The frame view holds the title bar and toolbar as well as the content.
            guard let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            return rep
        }

        /// The layers, bottom first, in one picture as large as `size` points.
        private static func composite(_ layers: [(NSBitmapImageRep, NSRect)], size: NSSize)
            -> NSBitmapImageRep?
        {
            guard let first = layers.first?.0 else { return nil }
            let scale = first.size.width > 0 ? CGFloat(first.pixelsWide) / first.size.width : 1
            guard
                let target = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                    pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: target)
            else { return nil }
            target.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (layer, rect) in layers { layer.draw(in: rect) }
            NSGraphicsContext.restoreGraphicsState()
            return target
        }

        private static func sibling(of url: URL, suffix: String) -> URL {
            let name = url.deletingPathExtension().lastPathComponent + suffix
            return url.deletingLastPathComponent().appending(path: name).appendingPathExtension(
                url.pathExtension.isEmpty ? "png" : url.pathExtension)
        }

        private static func write(_ rep: NSBitmapImageRep, to url: URL) {
            guard let png = rep.representation(using: .png, properties: [:]) else {
                say("no png for \(url.lastPathComponent)")
                return
            }
            do {
                try png.write(to: url)
                say("wrote \(url.path)")
            } catch {
                say("write failed: \(error)")
            }
        }
    }
#endif
