import CleanupKit
import SwiftUI

/// What iclean remembers between runs, and the tools for it (Constitution IV, spec 009 section
/// 6.12). Each tool is its own section with a footer that says what it does and what it leaves alone.
struct SavedDataView: View {
    @Environment(AppModel.self) private var model
    @State private var inventory: AppModel.SavedDataInventory?

    var body: some View {
        Form {
            SavedDataSections(inventory: $inventory)
        }
        .formStyle(.grouped)
        .navigationTitle("What iclean Remembers")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { inventory = await model.savedDataInventory() }
    }
}

/// The sections of that screen, so the Mac Settings window can show the same rows and tools in one
/// form. The host owns the inventory and loads it (a modifier on these sections would repeat on each).
struct SavedDataSections: View {
    @Environment(AppModel.self) private var model
    @Binding var inventory: AppModel.SavedDataInventory?
    @State private var confirmErase = false
    @State private var confirmReset = false
    @State private var confirmClearAlwaysKeep = false
    /// The count the dialog names, fixed when it opens so it does not change as it closes.
    @State private var alwaysKeepInDialog = 0

    var body: some View {
        Section {
            if let inventory {
                resultsRow(inventory)
                LabeledContent("Your selections") {
                    Text("\(inventory.decisionCount + inventory.keeperChoices)")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("saved.choices")
                LabeledContent("Always Keep") {
                    if inventory.keepMarkCount > 0 {
                        Text("^[\(inventory.keepMarkCount) photo](inflect: true)")
                    } else {
                        Text("None")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("saved.alwaysKeep")
            } else {
                // No identifiers until the numbers are real, so nothing reads a placeholder.
                placeholderRows
            }
        } footer: {
            Text(
                "iclean saves this so it can pick up where you left off. It notes which photos are grouped and what you chose, never the photos themselves, and none of it leaves this \(Device.noun)."
            )
        }
        clearResultsSection
        resetSection
        if let inventory, inventory.keepMarkCount > 0 { alwaysKeepSection(inventory) }
        if model.storeProblem != nil { eraseSection }
    }

    // MARK: Tools
    //
    // Each dialog sits on its own button, so the system points it at what it is about.

    private var clearResultsSection: some View {
        Section {
            Button {
                Task {
                    await model.clearSavedResults()
                    inventory = await model.savedDataInventory()
                }
            } label: {
                FormAction(title: "Clear Scan Results")
            }
            .buttonStyle(.borderless)
            .actionRow()
            .tint(Palette.accentText)
            .accessibilityIdentifier("saved.clearResults")
        } footer: {
            Text("iclean rebuilds these from your next scan. Nothing is lost.")
        }
    }

    private var resetSection: some View {
        Section {
            Button {
                confirmReset = true
            } label: {
                FormAction(title: "Reset Your Selections")
            }
            .buttonStyle(.borderless)
            .actionRow()
            .tint(Palette.accentText)
            .accessibilityIdentifier("saved.resetChoices")
            .confirmationDialog(
                "Reset Your Selections?", isPresented: $confirmReset, titleVisibility: .visible
            ) {
                Button("Reset") {
                    Task {
                        await model.resetReviewChoices()
                        inventory = await model.savedDataInventory()
                    }
                }
                .accessibilityIdentifier("saved.confirmReset")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "iclean forgets what you selected and which copies you chose to keep. Your photos are not touched."
                )
            }
        } footer: {
            Text(
                "Forgets what you selected and which copies you chose to keep. Your photos are not touched."
            )
        }
    }

    private func alwaysKeepSection(_ inventory: AppModel.SavedDataInventory) -> some View {
        Section {
            Button {
                alwaysKeepInDialog = inventory.keepMarkCount
                confirmClearAlwaysKeep = true
            } label: {
                FormAction(title: "Remove Always Keep from All Photos")
            }
            .buttonStyle(.borderless)
            .actionRow()
            .tint(Palette.accentText)
            .accessibilityIdentifier("saved.clearAlwaysKeep")
            .confirmationDialog(
                Text("Remove Always Keep from \(alwaysKeepInDialog) photos?"),
                isPresented: $confirmClearAlwaysKeep, titleVisibility: .visible
            ) {
                Button("Remove Always Keep") {
                    // This section goes away with the last mark: close the dialog's state now so
                    // it cannot come back when a mark is added later.
                    confirmClearAlwaysKeep = false
                    Task {
                        await model.clearKeepMarks()
                        self.inventory = await model.savedDataInventory()
                    }
                }
                .accessibilityIdentifier("saved.confirmClearAlwaysKeep")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "iclean may suggest them for removal again. Nothing is deleted from your library."
                )
            }
        } footer: {
            Text(
                "iclean may suggest them for removal again. Nothing is deleted from your library."
            )
        }
    }

    private var eraseSection: some View {
        Section {
            Button(role: .destructive) {
                confirmErase = true
            } label: {
                FormAction(title: "Delete Saved Data")
            }
            .buttonStyle(.borderless)
            .actionRow()
            .accessibilityIdentifier("saved.erase")
            .confirmationDialog(
                "Delete Saved Data?", isPresented: $confirmErase, titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await model.eraseSavedData() }
                }
                .accessibilityIdentifier("saved.confirmErase")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This starts iclean fresh. Your photos are not touched.")
            }
        } footer: {
            Text(
                "iclean can’t read its saved data. Deleting it starts fresh. Your photos are not touched."
            )
        }
    }

    // MARK: Rows

    /// The saved scan: its size and when it was made. "None" when nothing is saved.
    private func resultsRow(_ inventory: AppModel.SavedDataInventory) -> some View {
        LabeledContent {
            if let bytes = inventory.resultsBytes {
                Text(Format.byteValue(Int64(bytes)))
            } else {
                Text("None")
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scan results")
                if inventory.resultsBytes != nil, let built = inventory.resultsBuiltAt {
                    Text("Updated \(built.formatted(.relative(presentation: .named)))")
                        .font(Typography.note)
                        .foregroundStyle(Palette.quietText)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("saved.results")
    }

    private var placeholderRows: some View {
        Group {
            LabeledContent("Scan results") { Text("None") }
            LabeledContent("Your selections") { Text("0") }
            LabeledContent("Always Keep") { Text("None") }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

/// The label of a borderless button in a Form row: the whole width of the row and at least 44 pt
/// tall is the button, not only the words (a borderless button's hit area is its label).
private struct FormAction: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
}

extension View {
    /// A row that is only an action: its label is already 44 pt tall, so the row adds no padding of
    /// its own above and below (the sides keep the system's 16 pt).
    fileprivate func actionRow() -> some View {
        #if os(iOS)
            listRowInsets(EdgeInsets(top: 0, leading: Space.l, bottom: 0, trailing: Space.l))
        #else
            self
        #endif
    }
}
