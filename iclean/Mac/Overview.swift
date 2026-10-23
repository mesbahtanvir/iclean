#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// Keeps the content of a Form in a readable column. On a Mac the Form is itself the scroll view,
    /// so a maximum width on it would make the scroll view 560 pt wide, with its scroll bar floating
    /// in the middle of the window and the margins dead to the wheel. The Form keeps the whole pane,
    /// and the margins move its content in.
    private struct ReadableFormColumn: ViewModifier {
        @State private var width: CGFloat = 0

        func body(content: Content) -> some View {
            content
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
                .contentMargins(
                    .horizontal, max(0, (width - Layout.readable) / 2), for: .scrollContent)
        }
    }

    /// The Mac's front screen once there is something to show (spec 012 section 6.15): the hero, the
    /// one prominent button right under it, and the categories, in a centred column of a readable
    /// width. It is the phone's Home, laid out for a window.
    ///
    /// It reads only the cached selection summary: no photo file is read to draw it, and a progress
    /// tick does not reach it (the scan card and the toolbar read the progress).
    struct Overview: View {
        /// Opens the Confirm sheet for everything that is selected.
        let onReview: () -> Void
        /// A click on a category row selects it in the sidebar.
        let onSelect: (CleanupCategory) -> Void

        @Environment(AppModel.self) private var model

        var body: some View {
            let hasSelection = model.summary.count > 0
            // The summary is worked out a moment after the results arrive. Until then there is no
            // number to give, so the hero waits for it.
            let summaryReady = !model.summary.perCategory.isEmpty
            Form {
                if summaryReady { heroSection(hasSelection: hasSelection) }
                waitingSection
                categorySection
                footerSection
            }
            .formStyle(.grouped)
            .modifier(ReadableFormColumn())
            .calmAnimation(value: hasSelection)
        }

        // MARK: Sections

        /// The review to carry on and the newer results that were held back. They are here, and not
        /// only in the sidebar, so they can be reached while the sidebar is hidden.
        @ViewBuilder private var waitingSection: some View {
            let hasContinue = !model.continueRoute.isEmpty
            let hasNew = model.pendingNewCount > 0
            if hasContinue || hasNew {
                Section {
                    if hasContinue { MacContinueRow() }
                    if hasNew { ShowNewItemsRow() }
                }
            }
        }

        /// How much can be freed, said once and large, and the one next step directly under it. The
        /// button says "Review", not "Remove": it opens a summary, and nothing is removed until the
        /// person confirms there.
        private func heroSection(hasSelection: Bool) -> some View {
            Section {
                VStack(alignment: .leading, spacing: Space.l) {
                    HomeHero(summary: model.summary, isScanning: model.isScanning)
                    if hasSelection {
                        VStack(alignment: .leading, spacing: Space.s) {
                            reviewButton
                            ReviewNote(alignment: .leading)
                        }
                    }
                }
                .quietRow(top: Space.s, bottom: Space.s)
            }
        }

        private var reviewButton: some View {
            let count = model.summary.count
            return Button(action: onReview) {
                Text("Review ^[\(count) Item](inflect: true)…")
            }
            .prominentButtonStyle()
            .controlSize(.regular)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Opens a summary. Nothing is removed until you confirm.")
            .accessibilityIdentifier("results.reviewAll")
        }

        private var spokenLabel: String {
            let count = model.summary.count
            let title = String(
                agreeing: AttributedString(localized: "Review ^[\(count) Item](inflect: true)"))
            let size = SpokenBytes.string(model.summary.bytes, estimate: model.summary.isEstimate)
            return "\(title), \(size)"
        }

        @ViewBuilder private var categorySection: some View {
            if model.isScanning {
                // These are the finds so far; the scan is still going (004 FR-009).
                Section {
                    categoryRows
                } header: {
                    Text("Found so far")
                        .accessibilityIdentifier("results.foundSoFar")
                }
            } else {
                Section { categoryRows }
            }
        }

        /// The rows keep the categories' fixed order. A click selects the category in the sidebar,
        /// and the detail pane follows.
        private var categoryRows: some View {
            ForEach(model.results.categories) { result in
                Button {
                    onSelect(result.category)
                } label: {
                    HStack(spacing: Space.s) {
                        CategoryRow(category: result.category)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("results.category.\(result.category.rawValue)")
            }
        }

        /// The periphery, last: what was not checked, and the notices.
        @ViewBuilder private var footerSection: some View {
            let notScanned = model.results.notScannedCount
            if notScanned > 0 || !HomeNotices.isEmpty(model) {
                Section {
                    if notScanned > 0 { ICloudFootnote(count: notScanned).quietRow() }
                    if !HomeNotices.isEmpty(model) { HomeNotices().quietRow() }
                }
            }
        }
    }
#endif
