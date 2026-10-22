#if os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// The menu bar (spec 009 section 6.15): one window only, a Scan menu, selection commands under
    /// Edit, and a Help item that explains removal.
    ///
    /// The selection commands are added after the pasteboard group, never in place of it, so Copy,
    /// Paste and Select All keep working wherever the system wants them. They are off while a sheet is
    /// up or no category is in front, and the one that removes (`Remove Selected…`) only opens the
    /// Confirm sheet: nothing is removed from a menu.
    struct MacCommands: Commands {
        let model: AppModel

        @Environment(\.openWindow) private var openWindow
        @FocusedValue(\.reviewActions) private var review: ReviewActions?

        var body: some Commands {
            // One window only: one scan and one confirmation can be in progress, by construction.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) { AboutMenuItem() }
            CommandMenu("Scan") { ScanMenuItems(model: model) }
            CommandGroup(after: .pasteboard) {
                SelectionMenuItems(model: model, actions: review)
            }
            CommandGroup(replacing: .help) {
                Button("How Removal Works") { openWindow(id: HowRemovalWorks.windowID) }
            }
        }
    }

    /// "About iclean", with the one line this app can say about your photos.
    private struct AboutMenuItem: View {
        var body: some View {
            Button("About iclean") {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let credits = NSAttributedString(
                    string: String(
                        localized: "Everything stays on this Mac.",
                        comment: "The line in the About window"),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style,
                    ])
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
            }
        }
    }

    /// Scan Library (or Scan Again, or Resume), Pause or Resume, and Stop. Enabled from the model's
    /// state, the way the toolbar buttons are: the same `MacScanAction` decides both.
    private struct ScanMenuItems: View {
        let model: AppModel

        var body: some View {
            let sheetUp = MacSheetTracker.shared.isPresenting
            let start = MacScanAction.current(model)
            let paused = model.progress?.state == .paused
            let pauseTitle: LocalizedStringKey = paused ? "Resume Scan" : "Pause Scan"
            Button(startTitle(start)) { model.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(start == nil || sheetUp)
            Button(pauseTitle) {
                if paused { model.resumeScan() } else { model.pauseScan() }
            }
            .keyboardShortcut("p", modifiers: [.option, .command])
            .disabled(!model.isScanning || sheetUp)
            Button("Stop Scan") { model.stopScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isScanning || sheetUp)
        }

        /// The first scan is "Scan Library", the next ones "Scan Again", and a scan that was cut off
        /// is picked up again. Dimmed (nothing to start), it keeps the title it would have.
        private func startTitle(_ action: MacScanAction?) -> LocalizedStringKey {
            if let action { return action.title }
            if model.hasInterruptedScan { return MacScanAction.resume.title }
            return model.hasFinishedFullScan ? MacScanAction.again.title : MacScanAction.scan.title
        }
    }

    /// Select Suggested, Keep All and Remove Selected… for the screen in front.
    private struct SelectionMenuItems: View {
        let model: AppModel
        let actions: ReviewActions?

        var body: some View {
            Divider()
            let sheetUp = MacSheetTracker.shared.isPresenting
            let category = actions?.category
            let tally = category.flatMap { model.summary.perCategory[$0] }
            let canSelect = !sheetUp && (tally?.removable ?? 0) > 0
            let canKeep = !sheetUp && (tally?.selectedRemovable ?? 0) > 0
            // On the Overview the selection is everything; in a category it is that category's.
            let selected = category == nil ? model.summary.count : (tally?.selected ?? 0)
            Button(category == .largeVideos ? "Select All Videos" : "Select Suggested") {
                guard let category else { return }
                // Never a keeper: only the photos suggested for removal are in play.
                model.setSelected(model.results.category(category)?.removable ?? [], true)
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(!canSelect)
            Button("Keep All") {
                guard let category else { return }
                model.setSelected(model.results.category(category)?.removable ?? [], false)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!canKeep)
            // Opens the Confirm sheet and nothing else. There is no shortcut that removes.
            Button(category == nil ? "Review Selected…" : "Remove Selected…") {
                actions?.review()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(actions == nil || sheetUp || selected == 0)
        }
    }
#endif
