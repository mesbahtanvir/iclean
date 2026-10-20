import CleanupKit
import SwiftUI

/// One summary sheet before anything is removed (FR-012, FR-016).
struct ConfirmSheet: View {
    /// Only this category's selection, or everything when nil.
    var category: CleanupCategory?

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmWholeGroups = false
    @State private var isRemoving = false
    @State private var summary: CleanupSummary?
    /// What the removal will do, checked against the library when the sheet opened.
    @State private var plan: RemovalPlan?

    var body: some View {
        NavigationStack {
            if let summary, !summary.cancelled {
                DoneView(summary: summary) { dismiss() }
            } else if let plan {
                form(plan)
            } else {
                ProgressView("Checking your selection")
                    .accessibilityIdentifier("confirm.checking")
            }
        }
        .interactiveDismissDisabled(isRemoving)
        .task {
            model.removalError = nil
            plan = await model.makeRemovalPlan(category: category)
        }
    }

    private func form(_ plan: RemovalPlan) -> some View {
        let preview = model.removalPreview(plan)
        return List {
            Section {
                ForEach(
                    CleanupCategory.allCases.filter { preview.byCategory[$0] != nil }, id: \.self
                ) { c in
                    let t = preview.byCategory[c]!
                    LabeledContent(c.title) {
                        Text("\(t.count) · \(Format.bytes(t.bytes, estimate: preview.isEstimate))")
                    }
                }
            } header: {
                Text("You're about to remove")
            }
            .accessibilityIdentifier("confirm.summary")
            Section {
                LabeledContent("Total") {
                    Text(
                        "\(preview.count) items · \(Format.bytes(preview.bytes, estimate: preview.isEstimate))"
                    )
                    .bold()
                }
            } footer: {
                Text(
                    "They go to Recently Deleted in the Photos app, where you can restore them. iOS will ask you to confirm."
                )
            }
            if !preview.wholeGroupsSelected.isEmpty {
                Section {
                    Toggle(isOn: $confirmWholeGroups) {
                        Text(
                            "Remove every copy in \(preview.wholeGroupsSelected.count) groups. No copy of those photos will be kept."
                        )
                    }
                    .accessibilityIdentifier("confirm.removeAllWarning")
                }
            }
            if plan.droppedCount > 0 {
                Section {
                    Text(
                        "\(plan.droppedCount) left out: deleted, edited, made a favorite or no longer suggested since the scan."
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("confirm.dropped")
                }
            }
            if summary?.cancelled == true {
                Section { Text("Nothing was removed.").foregroundStyle(.secondary) }
            }
            if let error = model.removalError {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("confirm.error")
                }
            }
        }
        .navigationTitle("Remove \(preview.count) Items?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("confirm.cancel")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(role: .destructive) {
                Task {
                    isRemoving = true
                    summary = await model.remove(plan, confirmRemoveAll: confirmWholeGroups)
                    isRemoving = false
                    if summary?.cancelled == true { dismiss() }
                }
            } label: {
                Group {
                    if isRemoving { ProgressView() } else { Text("Remove \(preview.count) Items") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(
                isRemoving || preview.count == 0
                    || (!preview.wholeGroupsSelected.isEmpty && !confirmWholeGroups)
            )
            .padding()
            .accessibilityIdentifier("confirm.remove")
        }
    }
}
