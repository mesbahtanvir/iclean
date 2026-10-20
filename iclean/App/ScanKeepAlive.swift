import CleanupKit

/// What the user can expect from a running scan when they leave the window or the app.
/// Chosen by the platform's keep-alive and shown on the scanning screen.
enum ScanAllowance: Sendable {
    case unknown
    /// The system keeps the scan going and shows its progress outside the app (iOS 26
    /// continued processing task).
    case continues
    /// The scan pauses shortly after the user leaves and resumes by itself when they come
    /// back (iOS without a continued task).
    case pausesOnLeave
    /// The scan runs for as long as the app is running, hidden or not (Mac). It pauses
    /// for system sleep and resumes at wake.
    case runsWhileOpen
}

/// The one way the app asks the platform to keep a user-started scan alive (005 plan D2).
///
/// iPhone and iPad use `ScanContinuation`, the Mac uses `MacScanKeepAlive`. Nothing behind
/// this interface can remove photos, touch the network or leave a scan paused without
/// telling the user.
@MainActor
protocol ScanKeepAlive: AnyObject {
    var allowance: ScanAllowance { get }
    /// Resumes the scan the way the Resume button does; set by `AppModel`.
    var onAutoResume: (() -> Void)? { get set }

    func scanStarted(scanner: any CleanupKit.Scanner)
    func update(_ progress: ScanProgress)
    func scanPausedByUser()
    func scanResumedByUser()
    func scanEnded()
    func appDidEnterBackground()
    func appWillEnterForeground()
}

/// The keep-alive for the platform this build runs on.
@MainActor
func makePlatformScanKeepAlive() -> any ScanKeepAlive {
    #if os(macOS)
        MacScanKeepAlive()
    #else
        ScanContinuation()
    #endif
}
