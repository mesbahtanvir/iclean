#if os(macOS)
    import AppKit
    import CleanupKit
    import Observation
    import os

    /// Keeps a user-started scan running on the Mac (005 plan D2).
    ///
    /// A Mac app is not suspended when the user leaves it, but it can be slowed (App Nap),
    /// ended (automatic and sudden termination) or put to sleep with the Mac. While a scan
    /// runs this holds a process activity that rules out the first two and idle sleep, pauses
    /// the scan when the Mac goes to sleep (so a Vision or Photos request is not cut in half)
    /// and resumes it at wake. The pause is the lossless one of 002, with the reason that
    /// resumes by itself.
    ///
    /// Like `ScanContinuation`, this type has no way to remove photos and no network access.
    @MainActor @Observable
    final class MacScanKeepAlive: ScanKeepAlive {
        private(set) var allowance: ScanAllowance = .unknown
        var onAutoResume: (() -> Void)?

        @ObservationIgnored private let log = Logger(
            subsystem: "com.mesbahtanvir.iclean", category: "keepalive")
        @ObservationIgnored private var scanner: (any CleanupKit.Scanner)?
        @ObservationIgnored private var activity: (any NSObjectProtocol)?
        @ObservationIgnored private var observers: [any NSObjectProtocol] = []
        @ObservationIgnored private var isScanning = false
        @ObservationIgnored private var lastProgress: ScanProgress?
        @ObservationIgnored private var lastReported: ContinuousClock.Instant?
        /// The Mac went to sleep during the scan and the scan was paused for it: resume as
        /// soon as the Mac is awake and the paused event has arrived (it lags the pause).
        @ObservationIgnored private var pendingAutoResume = false
        @ObservationIgnored private var asleep = false
        /// The user paused inside the app; set by the user's own action.
        @ObservationIgnored private var userPaused = false

        init() {
            let center = NSWorkspace.shared.notificationCenter
            observers.append(
                center.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemWillSleep() }
                })
            observers.append(
                center.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemDidWake() }
                })
        }

        isolated deinit {
            let center = NSWorkspace.shared.notificationCenter
            observers.forEach(center.removeObserver)
            endActivity()
        }

        // MARK: Scan lifecycle (called by AppModel)

        func scanStarted(scanner: any CleanupKit.Scanner) {
            self.scanner = scanner
            isScanning = true
            lastProgress = nil
            lastReported = nil
            pendingAutoResume = false
            userPaused = false
            allowance = .runsWhileOpen
            beginActivity()
        }

        func update(_ progress: ScanProgress) {
            let previous = lastProgress
            lastProgress = progress
            // Thousands of events per scan; the log and the Dock need one a second.
            let now = ContinuousClock.now
            if previous?.state != progress.state
                || lastReported.map({ now - $0 >= .seconds(1) }) ?? true
            {
                lastReported = now
                trace(
                    "progress \(progress.processed)/\(progress.total) \(progress.state.rawValue)"
                        + " failed=\(progress.failed) notScanned=\(progress.notScanned)")
                showInDock(progress)
            }
            autoResumeIfDue()
        }

        /// A scan the user paused does not need to keep the Mac awake or the app alive.
        func scanPausedByUser() {
            pendingAutoResume = false
            userPaused = true
            endActivity()
        }

        func scanResumedByUser() {
            userPaused = false
            if isScanning { beginActivity() }
        }

        func scanEnded() {
            isScanning = false
            pendingAutoResume = false
            userPaused = false
            endActivity()
            clearDock()
            allowance = .unknown
        }

        // MARK: App lifecycle (called by AppModel)

        // A hidden or covered window is exactly what the activity assertion is for, so the
        // app moving to the background changes nothing on the Mac.
        func appDidEnterBackground() {}
        func appWillEnterForeground() {}

        // MARK: Sleep and wake

        private func systemWillSleep() {
            asleep = true
            guard isScanning, !userPaused, lastProgress?.state != .paused else { return }
            pendingAutoResume = true
            trace("Mac is going to sleep; pausing")
            let scanner = self.scanner
            Task { await scanner?.pause(reason: .backgroundLimit) }
        }

        private func systemDidWake() {
            asleep = false
            trace("Mac woke up")
            autoResumeIfDue()
        }

        private func autoResumeIfDue() {
            guard pendingAutoResume, isScanning, !asleep, !userPaused,
                lastProgress?.resumesOnForeground == true
            else { return }
            pendingAutoResume = false
            trace("Resuming after sleep")
            onAutoResume?()
        }

        // MARK: Process activity

        /// Held only while a scan is running and not paused by the user.
        private func beginActivity() {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [
                    .userInitiated, .idleSystemSleepDisabled, .automaticTerminationDisabled,
                    .suddenTerminationDisabled,
                ],
                reason: "iclean is scanning your photo library")
            trace("Activity assertion taken")
        }

        private func endActivity() {
            guard let activity else { return }
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            trace("Activity assertion released")
        }

        // MARK: Dock

        /// A thin accent bar over the icon, dimmed while paused: no red number.
        private func showInDock(_ progress: ScanProgress) {
            guard progress.state == .running || progress.state == .paused, progress.total > 0
            else { return clearDock() }
            DockProgress.shared.show(fraction: progress.fraction, paused: progress.state == .paused)
        }

        private func clearDock() {
            DockProgress.shared.clear()
        }

        // MARK: Logging

        private func trace(_ message: String) {
            log.info("\(message, privacy: .public)")
            #if DEBUG
                if Self.isTracing {
                    print(
                        "[scan] \(Date.now.formatted(date: .omitted, time: .standard)) \(message)")
                    fflush(stdout)
                }
            #endif
        }

        #if DEBUG
            /// `-TraceScan` mirrors the log to stdout so a scan can be watched from a terminal.
            private static let isTracing = ProcessInfo.processInfo.arguments.contains("-TraceScan")
        #endif
    }
#endif
