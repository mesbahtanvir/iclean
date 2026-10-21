#if DEBUG && os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// Debug only. Lets a Mac screen be looked at without Screen Recording permission (macOS blocks
    /// capture from outside the app): the app saves its own window as a PNG and quits.
    ///
    /// - `-SnapshotTo <file.png>`: save the window and quit.
    /// - `-SnapshotAfter <seconds>`: wait before saving (default 5).
    /// - `-WindowSize <width>x<height>`: size the window first.
    /// - `-OpenRoute category:<name>` or `group:<name>`: open a screen (needs results: use with
    ///   `-AutoScan`).
    /// - `-ShowScreen settings|saved|recent`: show that screen alone in the window.
    @MainActor
    enum WindowSnapshot {
        private static func value(_ flag: String) -> String? {
            let args = ProcessInfo.processInfo.arguments
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        /// A screen to show alone, for the screens that are not reached by a route.
        static var screenOverride: String? { value("-ShowScreen") }

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
                "saving after \(delay) s; windows: \(NSApp.windows.map { "\($0.className) visible=\($0.isVisible)" })"
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

        private static func save(to path: String) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                // The frame view holds the title bar and toolbar as well as the content.
                let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else {
                say("no window or bitmap")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                say("no png")
                return
            }
            do { try png.write(to: URL(fileURLWithPath: path)) } catch {
                say("write failed: \(error)")
            }
        }
    }
#endif
