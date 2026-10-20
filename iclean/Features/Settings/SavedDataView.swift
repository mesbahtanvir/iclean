import CleanupKit
import SwiftUI

/// What iclean keeps on this iPhone besides the scan, and the controls for it (Constitution IV).
struct SavedDataView: View {
    @Environment(AppModel.self) private var model
    @State private var inventory: AppModel.SavedDataInventory?
    @State private var confirmErase = false
    @State private var confirmReset = false

    var body: some View {
        List {
            Section {
                if let inventory {
                    LabeledContent("Saved results") {
                        if let bytes = inventory.resultsBytes {
                            Text(
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(bytes), countStyle: .file))
                        } else {
                            Text("None")
                        }
                    }
                    .accessibilityIdentifier("saved.results")
                    LabeledContent("Review choices") {
                        Text("\(inventory.decisionCount + inventory.keeperChoices)")
                    }
                    .accessibilityIdentifier("saved.choices")
                    if let built = inventory.resultsBuiltAt {
                        LabeledContent("Results saved") {
                            Text(built, format: .relative(presentation: .named))
                        }
                    }
                } else {
                    ProgressView()
                }
            } header: {
                Text("Kept on this iPhone")
            } footer: {
                Text(
                    "Saved results and your choices let iclean pick up where you left off after it closes. They hold photo identifiers, dates, sizes, which photos are grouped and what you chose, never the photos themselves, and never leave this iPhone."
                )
            }
            Section {
                Button("Clear Saved Results") {
                    Task {
                        await model.clearSavedResults()
                        inventory = await model.savedDataInventory()
                    }
                }
                .accessibilityIdentifier("saved.clearResults")
                Button("Reset Review Choices", role: .destructive) { confirmReset = true }
                    .accessibilityIdentifier("saved.resetChoices")
            } footer: {
                Text(
                    "Clearing saved results is safe: they are built again from your scan. Resetting review choices forgets which photos you ticked, which copy you chose to keep, and where you were."
                )
            }
            if model.storeProblem != nil {
                Section {
                    Button("Delete Saved Data", role: .destructive) { confirmErase = true }
                        .accessibilityIdentifier("saved.erase")
                } footer: {
                    Text(
                        "iclean cannot read its saved data. Deleting it starts fresh; your photos are not touched and the next scan rebuilds the results."
                    )
                }
            }
        }
        .navigationTitle("Saved on this iPhone")
        .task { inventory = await model.savedDataInventory() }
        .confirmationDialog(
            "Reset review choices?", isPresented: $confirmReset, titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                Task {
                    await model.resetReviewChoices()
                    inventory = await model.savedDataInventory()
                }
            }
            .accessibilityIdentifier("saved.confirmReset")
        }
        .confirmationDialog(
            "Delete saved data?", isPresented: $confirmErase, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.eraseSavedData() }
            }
            .accessibilityIdentifier("saved.confirmErase")
        }
    }
}
