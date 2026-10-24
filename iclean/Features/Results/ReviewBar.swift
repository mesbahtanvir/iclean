import CleanupKit
import SwiftUI

/// The one next step on Home: a full-width capsule that says how many items (spec 014: one line, no
/// sentence under it; the size is in the hero above and the reassurance is on the Confirm sheet).
/// It is the only filled control on the screen, it is shown only while something is selected
/// (hidden, never disabled), and it opens the Confirm sheet, which the host owns, so the sheet
/// outlives the bar.
struct ReviewBar: View {
    let summary: SelectionSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Review ^[\(summary.count) Item](inflect: true)")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("results.reviewAll.title")
        }
        .prominentButtonStyle()
        .controlSize(.large)
        // A pinned control stays a control at the largest sizes: at AX5 it filled a third of the
        // screen and covered the rows it sits over.
        .actionShape(pinned: true)
        // VoiceOver still hears the size, so the button and the hero agree out loud.
        .accessibilityLabel(spokenLabel)
        .accessibilityHint("Opens a summary. Nothing is removed until you confirm.")
        .accessibilityIdentifier("results.reviewAll")
    }

    private var spokenLabel: String {
        let count = summary.count
        let title = String(
            agreeing: AttributedString(localized: "Review ^[\(count) Item](inflect: true)"))
        return
            "\(title), \(SpokenBytes.string(summary.bytes, estimate: summary.isEstimate))"
    }
}

/// "Nothing is removed until you confirm." The reassurance that sits with the action it qualifies:
/// on the Mac Overview, under the hero. The phone says it on the Confirm sheet instead (spec 014).
struct ReviewNote: View {
    /// Centred under a pinned button on a phone; leading under the hero on a Mac.
    var alignment: TextAlignment = .center

    var body: some View {
        Text(
            "Nothing is removed until you confirm. Removed items go to Recently Deleted in Photos."
        )
        .font(Typography.note)
        .foregroundStyle(Palette.quietText)
        .multilineTextAlignment(alignment)
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("results.reviewNote")
    }
}
