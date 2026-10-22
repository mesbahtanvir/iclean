#if os(macOS)
    import CleanupKit
    import SwiftUI

    extension View {
        /// Makes a scroll view of photos one keyboard target (spec 012 section 6.15, spec 005
        /// FR-015/016): arrows move, Shift-arrows extend a range, Space toggles, Return opens, Delete
        /// opens the Confirm sheet. None of these removes anything.
        func gridKeys(
            _ navigator: GridNavigator, toggle: @escaping (String) -> Void,
            open: @escaping (String) -> Void, remove: @escaping () -> Void
        ) -> some View {
            modifier(MacGridKeys(navigator: navigator, toggle: toggle, open: open, remove: remove))
        }
    }

    /// One focus target for the whole grid, not one per photo. A grid of 30,000 photos is a single
    /// Tab stop, the target exists wherever the grid is scrolled to, and the photo the keyboard is on
    /// is a plain property of the navigator that only the ring of its cell reads.
    private struct MacGridKeys: ViewModifier {
        let navigator: GridNavigator
        let toggle: (String) -> Void
        let open: (String) -> Void
        let remove: () -> Void

        @FocusState private var hasKeyboard: Bool

        private static let arrows: Set<KeyEquivalent> = [
            .upArrow, .downArrow, .leftArrow, .rightArrow,
        ]

        func body(content: Content) -> some View {
            content
                .focusable()
                .focused($hasKeyboard)
                // The system's ring would be a rectangle around the whole grid.
                .focusEffectDisabled()
                .onChange(of: hasKeyboard) { _, has in navigator.isActive = has }
                .onAppear {
                    let binding = $hasKeyboard
                    navigator.takeKeyboard = { binding.wrappedValue = true }
                }
                // Space on the photo the keyboard is on. A held key repeats: only the first press
                // toggles, and the repeats are used up here so the scroll view does not take them
                // for a page down. With no photo yet, Space is the scroll view's own page down.
                .onKeyPress(.space, phases: [.down, .repeat]) { press in
                    guard navigator.focusedID != nil else { return .ignored }
                    if !press.isRepeat, let id = navigator.photoToAct() { toggle(id) }
                    return .handled
                }
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    guard let id = navigator.focusedID else { return .ignored }
                    if !press.isRepeat { open(id) }
                    return .handled
                }
                // The arrow keys. A plain one is a move command, below. Shift is not one, so it is
                // read here, and every other combination is left to the system.
                .onKeyPress(keys: Self.arrows, phases: [.down, .repeat]) { press in
                    let others: EventModifiers = [.command, .option, .control]
                    guard press.modifiers.contains(.shift),
                        press.modifiers.isDisjoint(with: others),
                        let direction = Self.direction(press.key)
                    else { return .ignored }
                    navigator.move(direction, extending: true)
                    return .handled
                }
                .onMoveCommand { navigator.move($0) }
                .onDeleteCommand(perform: remove)
        }

        private static func direction(_ key: KeyEquivalent) -> MoveCommandDirection? {
            switch key {
            case .upArrow: .up
            case .downArrow: .down
            case .leftArrow: .left
            case .rightArrow: .right
            default: nil
            }
        }
    }
#endif
