import CleanupKit
import SwiftUI

/// The receipt after a removal (FR-015): what was removed, the honest figure, and how to undo it.
/// Quiet on purpose: nothing was erased yet, so there is nothing to celebrate and nothing to fear.
/// When nothing was removed at all, it says only that, and says nothing about getting photos back.
struct DoneView: View {
    let summary: CleanupSummary
    var onClose: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 44
    @AccessibilityFocusState private var headlineFocused: Bool
    @State private var succeeded = false

    private var failed: Int { summary.failedAssetIDs.count }
    private var removedAnything: Bool { summary.removedCount > 0 }

    var body: some View {
        layout
            // One quiet success tap, and only when everything asked for happened.
            .sensoryFeedback(.success, trigger: succeeded)
            .task {
                if failed == 0 { succeeded = true }
                // VoiceOver starts on the headline, after the sheet has finished growing.
                try? await Task.sleep(for: .milliseconds(400))
                headlineFocused = true
            }
    }

    /// The receipt, with the one button: pinned to the bottom of a phone's sheet, and under the text
    /// at the foot of a Mac's, where the sheet is as tall as what it says and scrolls only when the
    /// screen is shorter.
    @ViewBuilder private var layout: some View {
        #if os(iOS)
            ScrollView { receipt }
                .pinnedBar(isPresented: true) { doneButton }
        #else
            VStack(spacing: 0) {
                ViewThatFits(in: .vertical) {
                    receipt
                    ScrollView { receipt }
                }
                HStack {
                    Spacer()
                    doneButton
                }
                .padding(Space.xl)
            }
        #endif
    }

    private var receipt: some View {
        VStack(spacing: Space.m) {
            Image(systemName: failed > 0 ? "info.circle" : "checkmark.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: glyphSize))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // Read by the tests as one text: exactly "N items removed", or "Nothing was removed".
            headline
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headlineFocused)
                .accessibilityIdentifier("done.removed")
            if removedAnything {
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
            if removedAnything { restoreGuidance }
        }
        .padding(.horizontal, platformGutter)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
        .readableColumn()
    }

    private var headline: Text {
        removedAnything
            ? Text("\(summary.removedCount) items removed") : Text("Nothing was removed")
    }

    /// One sentence about time in the primary colour, the steps one tap away, and the one thing they
    /// cannot promise. Not shown when nothing was removed: there is nothing to put back.
    private var restoreGuidance: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(RestoreHelp.retentionOnReceipt)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("done.restore")
            DisclosureGroup {
                RestoreSteps()
                    .padding(.top, Space.s)
            } label: {
                Text("How to put them back")
                    .font(.body)
                    .foregroundStyle(Palette.accentText)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    // On the label, not the group: an id on the group is given to the steps too.
                    .accessibilityIdentifier("done.howTo")
            }
            .tint(Palette.accentText)
            QuietNote(
                "If your photos are in iCloud, the space you get back on this device can differ.",
                systemImage: "icloud"
            )
            .accessibilityIdentifier("done.icloud")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.m)
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
        .prominentButtonStyle()
        #if os(iOS)
            .controlSize(.large)
        #else
            // On a Mac Return closes the receipt: there is nothing left to confirm.
            .keyboardShortcut(.defaultAction)
        #endif
        .actionShape(pinned: true)
        .accessibilityIdentifier("done.close")
    }
}
