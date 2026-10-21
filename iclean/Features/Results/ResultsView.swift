import CleanupKit
import SwiftUI

/// One row per category with count and space (FR-007).
struct ResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.results
        if results.categories.isEmpty {
            if model.isScanning, !model.isBuildingResults {
                // Nothing found yet, and the scan is not done: never claim the library is clean.
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Looking for things to clean up. Results appear here as they are found.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("results.checking")
                }
            } else if model.isBuildingResults {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Updating results…")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("results.updating")
                }
            } else if model.lastScanDate != nil, !model.isScanning {
                Section {
                    Label("Your library looks clean", systemImage: "checkmark.seal")
                        .accessibilityIdentifier("results.empty")
                } footer: {
                    if results.notScannedCount > 0 {
                        Text(
                            "\(results.notScannedCount) items were not scanned because only iCloud has them. iclean never downloads photos."
                        )
                        .accessibilityIdentifier("results.notScanned")
                    }
                }
            }
        } else {
            if model.pendingNewCount > 0 {
                Section {
                    Button {
                        model.showPendingResults()
                    } label: {
                        Label("\(model.pendingNewCount) new results. Show", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("results.showNew")
                }
            }
            Section {
                ForEach(results.categories) { result in
                    NavigationLink(value: Route.category(result.category)) {
                        CategoryRow(category: result.category)
                    }
                    .accessibilityIdentifier("results.category.\(result.category.rawValue)")
                }
            } header: {
                if model.isScanning, let p = model.progress, p.total > 0 {
                    // Rows are the finds so far; the scan is still going (004 FR-009).
                    Text("Found so far · checked \(p.processed) of \(p.total)")
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("results.foundSoFar")
                } else {
                    Text("Results")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if results.notScannedCount > 0 {
                        Text(
                            "\(results.notScannedCount) items were not scanned because only iCloud has them. iclean never downloads photos."
                        )
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
        let layout =
            typeSize.isAccessibilitySize
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
