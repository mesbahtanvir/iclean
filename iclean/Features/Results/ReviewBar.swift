import CleanupKit
import SwiftUI

/// The one next step on Home: a full-width capsule that says how many items and how much space, with
/// the reassurance directly under it. It is the only filled control on the screen, it is shown only
/// while something is selected (hidden, never disabled), and it opens the Confirm sheet, which the
/// host owns, so the sheet outlives the bar.
struct ReviewBar: View {
    let summary: SelectionSummary
    /// False at accessibility sizes, where the note joins the list so the pinned area is one button.
    var showsNote = true
    let action: () -> Void

    var body: some View {
        VStack(spacing: Space.s) {
            Button(action: action) {
                VStack(spacing: 2) {
                    Text("Review ^[\(summary.count) Item](inflect: true)")
                        .font(.headline)
                    Text(Format.bytes(summary.bytes, estimate: summary.isEstimate))
                        .font(.subheadline.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityLabel(spokenLabel)
            .accessibilityHint("Opens a summary. Nothing is removed until you confirm.")
            .accessibilityIdentifier("results.reviewAll")
            if showsNote { ReviewNote() }
        }
    }

    private var spokenLabel: String {
        let count = summary.count
        let title = String(
            agreeing: AttributedString(localized: "Review ^[\(count) Item](inflect: true)"))
        return
            "\(title), \(SpokenBytes.string(summary.bytes, estimate: summary.isEstimate))"
    }
}

/// "Nothing is removed until you confirm." The reassurance that sits with the action it qualifies.
struct ReviewNote: View {
    var body: some View {
        Text(
            "Nothing is removed until you confirm. Removed items go to Recently Deleted in Photos."
        )
        .font(Typography.note)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("results.reviewNote")
    }
}
