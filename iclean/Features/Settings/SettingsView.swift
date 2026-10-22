import CleanupKit
import SwiftUI

/// Settings, ordered by consequence (spec 009 section 6.11): three places to look, then the one
/// thing that cannot be undone, alone at the end.
struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    RecentScansView()
                } label: {
                    QuietRowLabel("Recent Scans", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("settings.recentScans")
                NavigationLink {
                    SavedDataView()
                } label: {
                    QuietRowLabel("What iclean Remembers", systemImage: "internaldrive")
                }
                .accessibilityIdentifier("settings.savedData")
                NavigationLink {
                    RestoreHelpView()
                } label: {
                    QuietRowLabel("Restore Removed Photos", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("settings.restoreHelp")
            } footer: {
                PrivacyNote()
            }
            DeleteAllSection()
            #if DEBUG
                Section {
                    NavigationLink("Baseline Library (Debug)") {
                        BaselineView(autoRun: false, standalone: false)
                    }
                    .accessibilityIdentifier("settings.baseline")
                } header: {
                    Text(verbatim: "Developer")
                }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

/// "Everything stays on this iPhone. No account, no internet connection, nothing collected." One
/// sentence, written once: Settings shows it under its rows and the Mac Settings window shows it too.
struct PrivacyNote: View {
    var body: some View {
        Text(
            "Everything stays on this \(Device.noun). No account, no internet connection, nothing collected."
        )
    }
}

/// The one thing that cannot be undone, alone in its own section: the only red text on the screen,
/// and it asks first. Settings and the Mac Settings window both show it.
struct DeleteAllSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false
    /// Called when the delete has finished, with whether it all went. The Mac Settings window shows
    /// the saved data next to this button and reads it again from here; the phone's Settings has
    /// no such screen and passes nothing.
    var onFinished: (@MainActor (Bool) -> Void)?

    var body: some View {
        Section {
            // The system's destructive role: the only red text on this screen.
            Button("Delete All iclean Data", role: .destructive) {
                confirmDelete = true
            }
            #if os(macOS)
                .buttonStyle(.borderless)
            #endif
            .accessibilityIdentifier("settings.deleteAllData")
            // On the button itself, so the system dialog points at what it is about.
            .confirmationDialog(
                "Delete All iclean Data?", isPresented: $confirmDelete,
                titleVisibility: .visible
            ) {
                Button("Delete All iclean Data", role: .destructive) {
                    Task {
                        let finished = await model.deleteAllData()
                        onFinished?(finished)
                    }
                }
                .accessibilityIdentifier("settings.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes scan results, your selections and Always Keep photos. Your photos are not touched."
                )
            }
        } footer: {
            Text(deleteFooter)
        }
    }

    /// What deleting does, and when the saved data is unreadable, that deleting starts fresh.
    private var deleteFooter: String {
        let base = String(
            localized:
                "Removes scan results, your selections and Always Keep photos. Your photos are not touched."
        )
        guard model.storeProblem != nil else { return base }
        return String(localized: "iclean couldn’t read its saved data. Deleting it starts fresh.")
            + " " + base
    }
}

/// A row's title with a quiet icon: the icon is a hint, the words are the content. The system's own
/// label style is kept so icons of different widths still line the titles up.
private struct QuietRowLabel: View {
    let title: LocalizedStringKey
    let systemImage: String

    init(_ title: LocalizedStringKey, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}
