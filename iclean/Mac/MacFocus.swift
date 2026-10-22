#if os(macOS)
    import CleanupKit
    import Observation
    import SwiftUI

    // What the menu bar and the screens inside the window need from each other (spec 012 section
    // 6.15). The shell publishes where the window is pointing; the menu commands read it. Nothing
    // here removes a photo: the commands only open the Confirm sheet, which is the one place a
    // removal is confirmed.

    /// The screen in front, for the Edit menu: which category it shows (nil on the Overview), the group
    /// whose compare screen is on top of it (nil when the category itself is in front), and how to
    /// open the Confirm sheet for it.
    struct ReviewActions {
        var category: CleanupCategory?
        /// The `.group` route of the compare screen that is on top of the category, if one is. The
        /// selection commands then act on that group alone, never on the whole category behind it.
        var group: Route?
        var review: @MainActor () -> Void
    }

    /// What the menu bar can do with the photo the keyboard is on in a category's grid.
    struct GridActions {
        let navigator: GridNavigator
        /// Opens the compare screen of the group that photo is in.
        let compare: @MainActor () -> Void

        /// Whether the keyboard is on a photo that is in a group of copies or similar shots.
        @MainActor var canCompare: Bool { navigator.focusedGroupID != nil }
    }

    extension FocusedValues {
        /// Published by the Mac shell while the Overview or a category is in the window. Nil when
        /// there is nothing to review (first run, scanning without results), so the commands are off.
        @Entry var reviewActions: ReviewActions?
        /// Published by a category's grid while it is in the window, for the commands that act on
        /// the photo the keyboard is on.
        @Entry var gridActions: GridActions?
    }

    extension EnvironmentValues {
        /// Opens the Confirm sheet for a category (nil: for everything). The shell owns the sheet, so
        /// it lives as long as the window does and a screen can disappear while its receipt is up.
        @Entry var openConfirm: (@MainActor (CleanupCategory?) -> Void)?
    }

    /// Counts the sheets that are up (the Confirm sheet, the viewer). The menu commands read it and
    /// switch themselves off while one is: a sheet is a question, and it should be answered first.
    @MainActor @Observable
    final class MacSheetTracker {
        static let shared = MacSheetTracker()

        private(set) var open = 0
        var isPresenting: Bool { open > 0 }

        func opened() { open += 1 }
        func closed() { open = max(0, open - 1) }
    }

    /// Where the window is pointing: the sidebar's choice and the group screens pushed on it. It lives
    /// outside the window's views, so a window that was closed and is opened again from the Dock
    /// comes back to the same place, which is also where `AppModel` thinks the person is (the held
    /// results, the saved place). Nothing here is persisted: a new launch starts at the Overview.
    @MainActor @Observable
    final class MacNavigation {
        static let shared = MacNavigation()

        var selection: SidebarItem = .overview
        /// The screens pushed inside the detail pane: group compare only, each a `.group` route.
        var groupPath: [Route] = []

        /// The review stack as `AppModel` knows it: the selected category, then the groups pushed on
        /// it. Nothing on the Overview.
        var route: [Route] {
            if case .category(let category) = selection {
                return [.category(category)] + groupPath
            }
            return []
        }

        /// Goes to a saved review stack (its first element is the sidebar's choice, the rest the
        /// groups), without animation: it is a restore, not a move the person made.
        func go(to path: [Route]) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if case .category(let category)? = path.first {
                    selection = .category(category)
                    groupPath = Array(path.dropFirst())
                } else {
                    selection = .overview
                    groupPath = []
                }
            }
        }
    }

    extension KeyPress {
        /// A key that is held down sends its press again and again. A command that flips something
        /// (Space on a photo) must act on the first press only, or holding the key blinks the photo
        /// on and off.
        var isRepeat: Bool { phase.contains(.repeat) }
    }

    extension View {
        /// Tells `MacSheetTracker` that this sheet is up for as long as it is on screen.
        func tracksSheet() -> some View {
            onAppear { MacSheetTracker.shared.opened() }
                .onDisappear { MacSheetTracker.shared.closed() }
        }
    }
#endif
