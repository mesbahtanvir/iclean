import SwiftUI

/// How to bring removed photos back. Removing is recoverable for at least 30 days, and this is the
/// permanent path to it (spec 011 section 6.14): reached from Settings and read again on the receipt.
enum RestoreHelp {
    /// How long they stay, and what happens then. Settings says it at the top of its page.
    static var retention: String {
        String(
            localized:
                "Removed photos stay in Recently Deleted in the Photos app for at least 30 days, then Photos erases them for good.",
            comment: "How long removed photos can be restored"
        )
    }

    /// The same sentence for the receipt, which is about the photos just removed.
    static var retentionOnReceipt: String {
        String(
            localized:
                "They stay in Recently Deleted for at least 30 days, then Photos erases them for good.",
            comment: "On the receipt after photos were removed: how long they can be restored"
        )
    }

    /// The steps, one short sentence each. Settings shows them on their own screen and the receipt
    /// shows the same ones, so the two can never disagree.
    static var steps: [String] {
        #if os(macOS)
            [
                String(localized: "Open Photos.", comment: "Restore step 1 on a Mac"),
                String(
                    localized: "Choose Recently Deleted in the sidebar.",
                    comment: "Restore step 2 on a Mac"),
                String(
                    localized: "Select the photos you want and click Recover.",
                    comment: "Restore step 3 on a Mac"),
            ]
        #else
            [
                String(localized: "Open Photos.", comment: "Restore step 1 on an iPhone"),
                String(
                    localized:
                        "Choose Albums, then Utilities, then Recently Deleted (Face ID or your passcode may be asked).",
                    comment: "Restore step 2 on an iPhone"),
                String(
                    localized: "Select the photos you want and tap Recover.",
                    comment: "Restore step 3 on an iPhone"),
            ]
        #endif
    }
}

/// The numbered steps, in the primary colour at reading size, and the one way to get the space back
/// sooner. One element for VoiceOver, so it is read through in order.
struct RestoreSteps: View {
    @ScaledMetric(relativeTo: .body) private var numberWidth: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(RestoreHelp.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(Palette.quietText)
                        .frame(minWidth: numberWidth, alignment: .trailing)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("To get the space back sooner, empty Recently Deleted there.")
                .font(Typography.note)
                .foregroundStyle(Palette.quietText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("restoreHelp.steps")
    }
}

/// How long removed photos stay, and the steps to put them back: the page, the Mac Settings window
/// and the Mac Help window all show this.
struct RestoreHelpContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(RestoreHelp.retention)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("restoreHelp.retention")
            VStack(alignment: .leading, spacing: Space.m) {
                Text("To put them back")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                RestoreSteps()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A short page with the restore steps. Nothing to tap: the answer is the text.
struct RestoreHelpView: View {
    var body: some View {
        ScrollView {
            RestoreHelpContent()
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.xl)
                .readableColumn()
        }
        .background(Color.platformBackground)
        .navigationTitle("Restore Removed Photos")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
