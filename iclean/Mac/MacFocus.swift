#if os(macOS)
    import CleanupKit
    import Observation
    import SwiftUI

    // What the menu bar and the screens inside the window need from each other (spec 009 section
    // 6.15). The shell publishes where the window is pointing; the menu commands read it. Nothing
    // here removes a photo: the commands only open the Confirm sheet, which is the one place a
    // removal is confirmed.

    /// The screen in front, for the Edit menu: which category it shows (nil on the Overview) and how
    /// to open the Confirm sheet for it.
    struct ReviewActions {
        var category: CleanupCategory?
        var review: @MainActor () -> Void
    }

    extension FocusedValues {
        /// Published by the Mac shell while the Overview or a category is in the window. Nil when
        /// there is nothing to review (first run, scanning without results), so the commands are off.
        @Entry var reviewActions: ReviewActions?
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

    extension View {
        /// Tells `MacSheetTracker` that this sheet is up for as long as it is on screen.
        func tracksSheet() -> some View {
            onAppear { MacSheetTracker.shared.opened() }
                .onDisappear { MacSheetTracker.shared.closed() }
        }
    }
#endif
