import CleanupKit
import SwiftUI

/// The receipt after a removal (FR-015): what was removed, the honest figure, and how to undo it.
/// Quiet on purpose: nothing was erased yet, so there is nothing to celebrate and nothing to fear.
struct DoneView: View {
    let summary: CleanupSummary
    var onClose: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 44
    @AccessibilityFocusState private var headlineFocused: Bool
    @State private var succeeded = false

    private var failed: Int { summary.failedAssetIDs.count }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.m) {
                Image(systemName: failed > 0 ? "info.circle" : "checkmark.circle")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: glyphSize))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Read by the tests as one text: exactly "N items removed".
                Text("\(summary.removedCount) items removed")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headlineFocused)
                    .accessibilityIdentifier("done.removed")
                if summary.removedCount > 0 {
                    // The honest figure: it is only free once Recently Deleted is emptied, and with
                    // iCloud Optimize Storage the space on this device can differ.
                    Text(
                        "You’ll get about \(Format.byteValue(summary.bytesFreed)) back once Recently Deleted is emptied"
                    )
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("done.freed")
                }
                if failed > 0 {
                    Text(
                        "\(failed) items could not be removed. They are still in your library."
                    )
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("done.failures")
                }
                Text(verbatim: restoreParagraph)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Space.m)
                    .accessibilityIdentifier("done.restore")
            }
            .padding(.horizontal, platformGutter)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.l)
            .readableColumn()
        }
        #if os(iOS)
            .pinnedBar(isPresented: true) { doneButton }
        #else
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack {
                    Spacer()
                    doneButton
                }
                .padding(Space.xl)
            }
        #endif
        // One quiet success tap, and only when everything asked for happened.
        .sensoryFeedback(.success, trigger: succeeded)
        .task {
            if failed == 0 { succeeded = true }
            // VoiceOver starts on the headline, after the sheet has finished growing.
            try? await Task.sleep(for: .milliseconds(400))
            headlineFocused = true
        }
    }

    /// The steps, then the one thing they cannot promise.
    private var restoreParagraph: String {
        RestoreHelp.steps + " "
            + String(
                localized:
                    "If your photos are in iCloud, the space you get back on this device can differ."
            )
    }

    private var platformGutter: CGFloat {
        #if os(macOS)
            Space.xl
        #else
            Space.l
        #endif
    }

    private var doneButton: some View {
        Button(action: onClose) {
            Text("Done")
                .font(.headline)
                #if os(iOS)
                    .frame(maxWidth: .infinity)
                #endif
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        #if os(iOS)
            .controlSize(.large)
        #endif
        .accessibilityIdentifier("done.close")
    }
}
