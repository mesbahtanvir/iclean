import CleanupKit
import SwiftUI

/// One row per category with count and space (FR-007).
struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.results
        if results.categories.isEmpty {
            if model.lastScanDate != nil, !model.isScanning {
                Section {
                    Label("Your library looks clean", systemImage: "checkmark.seal")
                        .accessibilityIdentifier("results.empty")
                } footer: {
                    if results.notScannedCount > 0 {
                        Text("\(results.notScannedCount) items were not scanned because only iCloud has them. iclean never downloads photos.")
                            .accessibilityIdentifier("results.notScanned")
                    }
                }
            }
        } else {
            Section {
                ForEach(results.categories) { result in
                    NavigationLink(value: result.category) {
                        CategoryRow(category: result.category)
                    }
                    .accessibilityIdentifier("results.category.\(result.category.rawValue)")
                }
            } header: {
                Text("Results")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if results.notScannedCount > 0 {
                        Text("\(results.notScannedCount) items were not scanned because only iCloud has them. iclean never downloads photos.")
                            .accessibilityIdentifier("results.notScanned")
                    }
                    Text("Removed items go to Recently Deleted in the Photos app.")
                }
            }
            Section {
                ReviewAllButton()
            }
        }
    }
}

struct CategoryRow: View {
    let category: CleanupCategory
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let totals = model.results.totals(for: category)
        let shown = model.results.category(category)?.allMembers.count ?? 0
        // Side by side normally; stacked at accessibility text sizes so nothing is cut off.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout())
        layout {
            Label(category.title, systemImage: category.systemImage)
                .fixedSize(horizontal: false, vertical: true)
            if !typeSize.isAccessibilitySize { Spacer() }
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing) {
                Text(category == .largeVideos ? "\(shown) videos" : "\(totals.count) items")
                Text(Format.bytes(totals.bytes, estimate: totals.isEstimate))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reviews the whole selection across all categories at once.
struct ReviewAllButton: View {
    @Environment(AppModel.self) private var model
    @State private var showConfirm = false

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            Label("Remove All Selected (\(model.selection.count))", systemImage: "trash")
        }
        .disabled(model.selection.isEmpty)
        .accessibilityIdentifier("results.reviewAll")
        .sheet(isPresented: $showConfirm) { ConfirmSheet() }
    }
}
