import SwiftUI
import BackgroundTasks
import Photos
import PhotoGateway
import ScanEngine
import ProposalStore
import CommitEngine
import Entitlements
import iCleanUI

@main
struct iCleanApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthGate()

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .environment(\.cardImageLoader, AppEnvironment.shared.imageLoader)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Entitlement listener starts before any UI (APP_PLATFORM.md §4.2).
        AppEnvironment.shared.startEntitlements()
        // One BG identifier, registered at launch (SCAN_PIPELINE.md §8).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppEnvironment.backgroundTaskIdentifier,
            using: nil
        ) { task in
            AppEnvironment.shared.handleBackgroundTask(task as! BGProcessingTask)
        }
        // Idempotent commit-journal recovery (APP_PLATFORM.md §2.1 step 5).
        Task { try? await AppEnvironment.shared.commitRunner?.recoverPendingJournals() }
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        AppEnvironment.shared.scheduleBackgroundScanIfNeeded()
    }
}

// MARK: - Auth gate (APP_PLATFORM.md §3)

@MainActor
final class AuthGate: ObservableObject {
    enum State {
        case undetermined
        case authorized
        case limited
        case denied
        case restricted
    }

    @Published var state: State = .undetermined

    init() {
        refresh()
    }

    func refresh() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: state = .authorized
        case .limited: state = .limited
        case .denied: state = .denied
        case .restricted: state = .restricted
        default: state = .undetermined
        }
    }

    /// Always .readWrite — the app deletes and writes album membership;
    /// never request add-only (APP_PLATFORM.md §3).
    func request() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                if case .authorized = self?.state { AppEnvironment.shared.startFirstScanIfNeeded() }
                if case .limited = self?.state { AppEnvironment.shared.startFirstScanIfNeeded() }
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var auth: AuthGate

    var body: some View {
        switch auth.state {
        case .undetermined:
            PermissionPrimerView { auth.request() }
        case .authorized, .limited:
            MainNavigationView(isLimited: auth.state == .limited)
                .onAppear { AppEnvironment.shared.startFirstScanIfNeeded() }
        case .denied:
            ZeroStateView(
                message: "iClean needs photo access to find duplicates and junk.",
                showsSettingsLink: true
            )
        case .restricted:
            // Parental controls: don't promise Settings can fix it (APP_PLATFORM.md §3).
            ZeroStateView(
                message: "Photo access is restricted on this device.",
                showsSettingsLink: false
            )
        }
    }
}

/// The safety-nets pre-prompt (DESIGN.md §10 first-run flow): the four nets,
/// privacy, and the price — before the OS dialog.
struct PermissionPrimerView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("iClean").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("Everything runs on this phone. Nothing is uploaded.", systemImage: "iphone")
                Label("Nothing deletes while you swipe — you review one list, then confirm.", systemImage: "tray")
                Label("Deleted photos sit in Recently Deleted for 30 days.", systemImage: "clock.arrow.circlepath")
                Label("Your first cleanup is free. $2.99 once unlocks the rest.", systemImage: "tag")
            }
            .font(.callout)
            .padding()
            Spacer()
            Button {
                onContinue()
            } label: {
                Text("Allow photo access").font(.headline).frame(maxWidth: .infinity).padding(6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

struct ZeroStateView: View {
    let message: String
    let showsSettingsLink: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44))
            Text(message).multilineTextAlignment(.center)
            if showsSettingsLink, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
            }
        }
        .padding()
    }
}

struct MainNavigationView: View {
    let isLimited: Bool
    @StateObject private var homeModel = HomeViewModel(store: AppEnvironment.shared.deckStore!)
    @State private var path: [Route] = []

    enum Route: Hashable {
        case deck(Family)
        case commit
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if isLimited {
                    // Honesty scoping (APP_PLATFORM.md §3): numbers are the selection's.
                    Text("Scanning the photos you've shared with iClean")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(6)
                        .background(.yellow.opacity(0.2))
                }
                HomeView(
                    model: homeModel,
                    onOpenFamily: { path.append(.deck($0)) },
                    onOpenBin: { path.append(.commit) }
                )
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .deck(let family):
                    DeckView(model: DeckViewModel(family: family, store: AppEnvironment.shared.deckStore!))
                case .commit:
                    CommitReviewView(model: CommitViewModel(
                        store: AppEnvironment.shared.deckStore!,
                        runner: AppEnvironment.shared.commitRunner!
                    ))
                }
            }
        }
    }
}
