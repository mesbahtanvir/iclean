import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct icleanApp: App {
    @State private var model = AppModel(environment: .live())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(macOS)
            // One window only: with no New Window item, the tab bar's plus button (View > Show Tab
            // Bar, Window > Merge All Windows) would still make a second one, with its own sheets.
            NSWindow.allowsAutomaticWindowTabbing = false
        #endif
        #if DEBUG
            #if os(macOS)
                // AppKit opens every launch argument that is not a flag as a file, and a SwiftUI
                // app asked to open a file shows no window. `-DemoScenario standard` would hide
                // the window (and UI tests launch with such arguments), so this turns it off.
                UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
            #endif
            NetworkTripwire.installIfRequested()
            if BaselineMode.isRequested && !DebugSafety.allowsLibraryWrites {
                DebugSafety.refuse("-BaselineRun")
            }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                // `-BaselineRun` shows only the baseline check and leaves the app's own
                // library, store and results alone. On a Mac it writes into the real library,
                // so it also needs `-AllowRealLibrary`.
                if BaselineMode.isRequested && DebugSafety.allowsLibraryWrites {
                    BaselineView(autoRun: true)
                } else {
                    appRoot
                }
            #else
                appRoot
            #endif
        }
        #if os(macOS)
            // A Mac window, not a phone: wide enough for a sidebar and a column of photos. The
            // contents set the minimum (`appRoot`), so it can never be made a sliver.
            .defaultSize(width: 1040, height: 700)
            .windowResizability(.contentMinSize)
            // One window only (no New Window), the Scan menu, selection commands and Help.
            .commands { MacCommands(model: model) }
        #endif
        #if os(macOS)
            // Command-comma.
            Settings { MacSettingsView().environment(model) }
            // Help: what removing does and how to undo it. Opened from the menu, never at launch.
            Window("How Removal Works", id: HowRemovalWorks.windowID) { HowRemovalWorksView() }
                .windowResizability(.contentSize)
                .defaultLaunchBehavior(.suppressed)
                .restorationBehavior(.disabled)
        #endif
    }

    private var appRoot: some View {
        rootContent
            #if os(macOS)
                .frame(minWidth: 820, minHeight: 540)
            #endif
            .environment(model)
            .task {
                #if DEBUG
                    await DebugSeeding.runIfRequested()
                #endif
                await model.onLaunch()
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-AutoScan") {
                        model.startScan()
                    }
                    #if os(macOS)
                        await WindowSnapshot.runIfRequested(model: model)
                    #endif
                #endif
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await model.onForeground() }
                case .inactive: model.flushForBackground()
                case .background:
                    model.flushForBackground()
                    model.onBackground()
                @unknown default: break
                }
            }
    }
}

extension icleanApp {
    /// The app's root; in a Mac debug build `-ShowScreen` shows one screen alone (WindowSnapshot).
    @ViewBuilder fileprivate var rootContent: some View {
        #if DEBUG && os(macOS)
            switch WindowSnapshot.screenOverride {
            case "settings": NavigationStack { SettingsView() }
            case "saved": NavigationStack { SavedDataView() }
            case "recent": NavigationStack { RecentScansView() }
            // The Mac Settings window's tabs and the Help window, in the main window so they can be
            // captured (the real windows are separate scenes).
            case "settingsGeneral": MacSettingsView(tab: .general)
            case "settingsData": MacSettingsView(tab: .data)
            case "help": HowRemovalWorksView()
            default: RootView()
            }
        #else
            RootView()
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Limited access is Home with a quiet note, not a different screen.
        let hasAccess = model.access == .full || model.access == .limited
        ZStack {
            if hasAccess {
                #if os(macOS)
                    // A sidebar and a detail pane, not a phone's stack of screens.
                    SplitRootView().transition(.opacity)
                #else
                    HomeView().transition(.opacity)
                #endif
            } else {
                AccessView().transition(.opacity)
            }
        }
        // Allowing access fades to Home: the app heard you, and nothing more.
        .calmAnimation(value: hasAccess)
    }
}
