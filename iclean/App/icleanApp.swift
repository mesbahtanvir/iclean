import SwiftUI

@main
struct icleanApp: App {
    @State private var model = AppModel(environment: .live())
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
            .defaultSize(width: 560, height: 780)
            // Small enough for a narrow window, but never a sliver; the contents set the minimum.
            .windowResizability(.contentMinSize)
            .commands {
                // One window only: one scan and one confirmation can be in progress, by construction.
                CommandGroup(replacing: .newItem) {}
            }
        #endif
    }

    private var appRoot: some View {
        rootContent
            #if os(macOS)
                .frame(minWidth: 480, minHeight: 560)
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
                HomeView().transition(.opacity)
            } else {
                AccessView().transition(.opacity)
            }
        }
        // Allowing access fades to Home: the app heard you, and nothing more.
        .calmAnimation(value: hasAccess)
    }
}
