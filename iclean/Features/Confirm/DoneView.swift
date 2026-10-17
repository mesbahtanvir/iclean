import CleanupKit
import SwiftUI

/// What was removed and how much space was freed (FR-015).
struct DoneView: View {
    let summary: CleanupSummary
    var onClose: () -> Void

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("\(summary.removedCount) items removed")
                        .font(.title2.bold())
                        .accessibilityIdentifier("done.removed")
                    Text("\(Format.bytes(summary.bytesFreed, estimate: summary.isEstimate)) freed")
                        .accessibilityIdentifier("done.freed")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
            } footer: {
                Text("The space is fully freed once Recently Deleted in the Photos app is emptied.")
            }
            if !summary.failedAssetIDs.isEmpty {
                Section("Not removed") {
                    Text("\(summary.failedAssetIDs.count) items could not be removed. They are still in your library.")
                        .accessibilityIdentifier("done.failures")
                }
            }
        }
        .navigationTitle("Done")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Close", action: onClose).accessibilityIdentifier("done.close")
            }
        }
    }
}
