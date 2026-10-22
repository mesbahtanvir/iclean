#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// "Continue reviewing" over "Duplicates, 3 selected", and a dismiss button: the phone's row
    /// (`ContinueReviewingRow`), but taking the person there itself.
    ///
    /// The phone's row asks the model to put the review back and Home applies it only while its
    /// stack is empty. A Mac window can be anywhere when the row is clicked (a category is already
    /// open, or a group), so this row applies the route in every state and the button always does
    /// what it says. It is in the sidebar footer and, on the Overview, in the detail pane, so it is
    /// there while the sidebar is hidden too.
    struct MacContinueRow: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            let category: CleanupCategory? = model.continueRoute.compactMap {
                if case .category(let c) = $0 { c } else { nil }
            }.first
            HStack(spacing: Space.s) {
                Button {
                    continueReviewing()
                } label: {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Continue reviewing")
                            .font(.headline)
                            .foregroundStyle(.tint)
                        if let category {
                            Text("\(category.title), \(model.selectedCount(in: category)) selected")
                                .font(Typography.note)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: Hit.minimum, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("home.continue")
                Button {
                    model.dismissContinue()
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(minWidth: Hit.minimum, minHeight: Hit.minimum)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("home.continueDismiss")
            }
        }

        /// The model works out the place and checks it against the results as they are now; this
        /// goes there, whatever the window shows, and uses the route up so none is left behind.
        private func continueReviewing() {
            model.continueReviewing()
            guard let restored = model.restoredRoute else { return }
            model.restoredRoute = nil
            MacNavigation.shared.go(to: restored.path)
        }
    }
#endif
