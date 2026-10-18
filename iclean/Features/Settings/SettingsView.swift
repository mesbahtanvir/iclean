import CleanupKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                Label {
                    Text(
                        "Everything stays on this iPhone. iclean never connects to the internet, has no account, and collects nothing."
                    )
                } icon: {
                    Image(systemName: "lock.shield")
                }
            } header: {
                Text("Privacy")
            }
            Section {
                Button("Clear \"Always Keep\" Marks") {
                    Task { await model.clearKeepMarks() }
                }
                .accessibilityIdentifier("settings.clearKeepMarks")
                Button("Delete All iclean Data", role: .destructive) {
                    confirmDelete = true
                }
                .accessibilityIdentifier("settings.deleteAllData")
            } footer: {
                Text(
                    "Deletes scan results, \"Always Keep\" marks and progress. Your photos are not touched."
                )
            }
            Section {
                NavigationLink("Recent Scans") { RecentScansView() }
                    .accessibilityIdentifier("settings.recentScans")
            }
            #if DEBUG
                Section {
                    NavigationLink("Baseline Library (Debug)") { BaselineView(autoRun: false) }
                        .accessibilityIdentifier("settings.baseline")
                }
            #endif
        }
        .navigationTitle("Settings")
        .confirmationDialog(
            "Delete all iclean data?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteAllData() }
            }
            .accessibilityIdentifier("settings.confirmDelete")
        }
    }
}
