#if os(macOS)
    import SwiftUI

    /// The Help window: what removing does and how to undo it (spec 009 sections 6.14 and 6.15).
    /// Local text only; no page is loaded and no link leaves the app.
    enum HowRemovalWorks {
        static let windowID = "restore"
    }

    struct HowRemovalWorksView: View {
        var body: some View {
            VStack(alignment: .leading, spacing: Space.xl) {
                step(
                    symbol: "checkmark.circle", title: Text("You decide"),
                    text: Text(
                        "iclean suggests what to remove. Nothing is removed until you review the list and confirm."
                    ))
                step(
                    symbol: "trash.circle", title: Text("Photos move to Recently Deleted"),
                    text: Text(
                        "Removed photos go to Recently Deleted in Photos. Photos will ask you to confirm once more."
                    ))
                step(
                    symbol: "arrow.uturn.backward.circle", title: Text("You can put them back"),
                    text: Text(verbatim: RestoreHelp.steps)
                )
                .accessibilityIdentifier("restoreHelp.steps")
            }
            .padding(Space.xl)
            .frame(width: Layout.macSheet + 2 * Space.xl, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }

        private func step(symbol: String, title: Text, text: Text) -> some View {
            HStack(alignment: .top, spacing: Space.m) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xs) {
                    title.font(.headline)
                    text
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
#endif
