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
            RootView()
                .environment(model)
                .task {
                    #if DEBUG
                        await DebugSeeding.runIfRequested()
                    #endif
                    await model.onLaunch()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.onForeground() } }
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
