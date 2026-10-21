import SwiftUI

/// How to bring removed photos back. Removing is recoverable for at least 30 days, and this is the
/// permanent path to it (spec 009 section 6.14): reached from Settings and read again on the receipt.
enum RestoreHelp {
    /// The steps, written once. Settings shows them on their own screen and the receipt after a
    /// removal shows the same words, so the two can never disagree.
    static var steps: String {
        #if os(macOS)
            String(
                localized:
                    "Removed photos stay in Recently Deleted in the Photos app for at least 30 days. To bring one back, open Photos, choose Recently Deleted in the sidebar, select the photos you want and click Recover. To get the space back sooner, empty Recently Deleted there.",
                comment: "How to restore removed photos on a Mac"
            )
        #else
            String(
                localized:
                    "Removed photos stay in Recently Deleted in the Photos app for at least 30 days. To bring one back, open Photos, choose Albums, scroll to Utilities, then choose Recently Deleted (it may ask for Face ID or your passcode). Select the photos you want and tap Recover. To get the space back sooner, empty Recently Deleted there.",
                comment: "How to restore removed photos on an iPhone"
            )
        #endif
    }
}

/// A short page with the restore steps. Nothing to tap: the answer is the text.
struct RestoreHelpView: View {
    var body: some View {
        ScrollView {
            Text(RestoreHelp.steps)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.xl)
                .readableColumn()
                .accessibilityIdentifier("restoreHelp.steps")
        }
        .background(Color.platformBackground)
        .navigationTitle("Restore Removed Photos")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
