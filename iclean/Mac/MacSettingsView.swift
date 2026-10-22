#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// The Settings window (Command-comma): two tabs, General and Your Data, in a fixed 480 pt
    /// column (spec 009 section 6.15). The same rows, tools and dialogs as the iPhone's Settings, but
    /// on two panes instead of pushed screens: a Mac has no back button to find its way home.
    struct MacSettingsView: View {
        enum Tab: Hashable {
            case general
            case data
        }

        @State private var tab: Tab

        init(tab: Tab = .general) { _tab = State(initialValue: tab) }

        var body: some View {
            TabView(selection: $tab) {
                GeneralPane()
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(Tab.general)
                YourDataPane()
                    .tabItem { Label("Your Data", systemImage: "internaldrive") }
                    .tag(Tab.data)
            }
        }
    }

    /// The privacy line and how to bring removed photos back.
    private struct GeneralPane: View {
        var body: some View {
            Form {
                Section {
                    Label {
                        PrivacyNote().fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .labelStyle(.quiet)
                } header: {
                    Text("Privacy")
                }
                Section {
                    RestoreHelpContent()
                        .accessibilityIdentifier("restoreHelp.steps")
                } header: {
                    Text("Restore Removed Photos")
                }
            }
            .formStyle(.grouped)
            .frame(width: Layout.macSettings, height: 360)
        }
    }

    /// What iclean remembers and the tools for it, the recent scans, and, alone at the end, the one
    /// thing that cannot be undone.
    private struct YourDataPane: View {
        @Environment(AppModel.self) private var model
        @State private var inventory: AppModel.SavedDataInventory?
        @State private var history: ScanHistory?

        var body: some View {
            Form {
                SavedDataSections(inventory: $inventory)
                if let history { RecentScansSection(history: history) }
                DeleteAllSection()
            }
            .formStyle(.grouped)
            .frame(width: Layout.macSettings, height: 560)
            .task { inventory = await model.savedDataInventory() }
            .task { history = ScanHistory(await model.recentSessions()) }
        }
    }
#endif
