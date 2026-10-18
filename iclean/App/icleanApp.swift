import SwiftUI

@main
struct icleanApp: App {
    @State private var model = AppModel(environment: .live())
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
            NetworkTripwire.installIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                // `-BaselineRun` shows only the baseline check and leaves the app's own
                // library, store and results alone.
                if BaselineMode.isRequested {
                    BaselineView(autoRun: true)
                } else {
                    appRoot
                }
            #else
                appRoot
            #endif
        }
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
                case .background: model.onBackground()
                default: break
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
