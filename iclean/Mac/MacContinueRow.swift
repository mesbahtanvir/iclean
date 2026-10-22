#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// "Continue reviewing" over "Duplicates, 3 selected", and a dismiss button: the phone's row
    /// (`ContinueReviewingRow`), but taking the person there through the window's shell.
    ///
    /// The phone's row asks the model to put the review back and Home applies it only while its
    /// stack is empty. A Mac window can be anywhere when the row is clicked (a category is already
    /// open, or a group), so the shell applies the route in every state, and the button always does
    /// what it says. It is in the sidebar footer and, on the Overview, in the detail pane, so it is
    /// there while the sidebar is hidden too.
    struct MacContinueRow: View {
        @Environment(AppModel.self) private var model
        @Environment(\.continueReviewing) private var continueReviewing

        var body: some View {
            let category: CleanupCategory? = model.continueRoute.compactMap {
                if case .category(let c) = $0 { c } else { nil }
            }.first
            HStack(spacing: Space.s) {
                Button {
                    if let continueReviewing {
                        continueReviewing()
                    } else {
                        model.continueReviewing()
                    }
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
    }
#endif
