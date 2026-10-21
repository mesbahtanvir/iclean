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
        #endif
    }

    private var appRoot: some View {
        RootView()
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

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.access {
        case .full, .limited:
            HomeView()
        case .notDetermined, .denied:
            AccessView()
        }
    }
}
