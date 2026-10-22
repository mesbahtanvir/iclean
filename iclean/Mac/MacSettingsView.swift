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

        @Environment(AppModel.self) private var model
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
            // A Delete All that failed says so here, in the window where the button was pressed:
            // the main window may be closed, or have a sheet up that no alert can be shown over.
            // Nothing else sets this message on a Mac, so the main window shows none.
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
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
        @Environment(\.controlActiveState) private var activeState
        @State private var inventory: AppModel.SavedDataInventory?
        @State private var history: ScanHistory?

        var body: some View {
            Form {
                SavedDataSections(inventory: $inventory)
                if let history { RecentScansSection(history: history) }
                // The pane shows what is saved and this deletes it, so whatever the outcome the
                // pane is read again: it never keeps showing data that is gone (the Always Keep
                // section goes with the last mark), or claims a delete that did not happen.
                DeleteAllSection { _ in Task { await reload() } }
            }
            .formStyle(.grouped)
            .frame(width: Layout.macSettings, height: 560)
            .task { await reload() }
            // This window outlives the scans and removals of the main window: it is read again
            // when it comes to the front and when a scan starts or ends.
            .onChange(of: activeState) { _, state in
                if state == .key { Task { await reload() } }
            }
            .onChange(of: model.isScanning) { Task { await reload() } }
        }

        private func reload() async {
            inventory = await model.savedDataInventory()
            history = ScanHistory(await model.recentSessions())
        }
    }
#endif
