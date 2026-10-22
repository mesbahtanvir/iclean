#if os(iOS)
    import BackgroundTasks
    import CleanupKit
    import Observation
    import UIKit
    import os

    /// Keeps a user-started scan running after the user leaves the app and feeds its
    /// progress to the system's own progress display in the Dynamic Island and on the Lock
    /// Screen (002 research R1, R2).
    ///
    /// This is the only type in the app that uses BackgroundTasks or UIKit background time.
    /// It has no way to remove photos (002 guarantee G5). The Mac has its own `ScanKeepAlive`.
    @MainActor @Observable
    final class ScanContinuation: ScanKeepAlive {
        private(set) var allowance: ScanAllowance = .unknown

        private static let identifierPrefix = "com.mesbahtanvir.iclean.scan."
        private let log = Logger(subsystem: "com.mesbahtanvir.iclean", category: "continuation")

        private var scanner: (any CleanupKit.Scanner)?
        private var isScanning = false
        private var lastProgress: ScanProgress?
        /// When the system display and the log were last updated.
        private var lastReported: ContinuousClock.Instant?
        /// A submitted request whose task has not started yet.
        private var queuedIdentifier: String?
        /// The running continued processing task (a `ContinuedTaskBox`; typed loosely
        /// because the task type needs iOS 26).
        private var running: AnyObject?
        private var graceTask: UIBackgroundTaskIdentifier = .invalid
        /// True while a continued processing request is being registered and submitted.
        private var submitting = false
        /// The grace period ran out and the scan was paused for lack of background time:
        /// resume as soon as the app is active again or a continued task covers it. Decided
        /// from the paused event itself, which arrives after the asynchronous pause
        /// (review fix: the last event can lag the pause).
        private var pendingAutoResume = false
        private var appIsActive = true
        /// The user paused inside the app. Set by the user's own action, not read from the
        /// last progress event, which still says "paused" right after Resume.
        private var userPaused = false
        /// Resumes the scan the way the Resume button does; set by `AppModel`.
        var onAutoResume: (() -> Void)?

        // MARK: Scan lifecycle (called by AppModel)

        func scanStarted(scanner: any CleanupKit.Scanner) {
            self.scanner = scanner
            isScanning = true
            lastProgress = nil
            lastReported = nil
            pendingAutoResume = false
            userPaused = false
            requestContinuation()
        }

        func update(_ progress: ScanProgress) {
            let previous = lastProgress
            lastProgress = progress
            // A 30,000-photo scan sends thousands of events. The system's progress display and the
            // log need a few a second at most, and every title update is a call into another
            // process.
            let now = ContinuousClock.now
            let changedKind =
                previous?.state != progress.state
                || previous?.isThermalPaused != progress.isThermalPaused
                || previous?.pauseReason != progress.pauseReason
            if changedKind || lastReported.map({ now - $0 >= .seconds(1) }) ?? true {
                lastReported = now
                trace(
                    "progress \(progress.processed)/\(progress.total) \(progress.state.rawValue)"
                        + " failed=\(progress.failed) notScanned=\(progress.notScanned)")
                if #available(iOS 26.0, *), let box = running as? ContinuedTaskBox {
                    box.apply(progress)
                }
            }
            autoResumeIfDue()
        }

        /// Pausing inside the app stops background work and hides the display (FR-011).
        func scanPausedByUser() {
            pendingAutoResume = false
            userPaused = true
            endContinuation(success: true)
        }

        func scanResumedByUser() {
            userPaused = false
            // A task that is queued or running already covers the scan.
            guard isScanning, running == nil, queuedIdentifier == nil else { return }
            requestContinuation()
        }

        func scanEnded() {
            isScanning = false
            pendingAutoResume = false
            userPaused = false
            endContinuation(success: true)
            allowance = .unknown
        }

        private func autoResumeIfDue() {
            guard pendingAutoResume, isScanning, lastProgress?.resumesOnForeground == true,
                appIsActive || running != nil
            else { return }
            pendingAutoResume = false
            trace("Resuming after background time ran out")
            onAutoResume?()
        }

        // MARK: App lifecycle (called by AppModel)

        /// Without a continued processing task, use the short grace period iOS grants every
        /// app, then pause losslessly (research R2).
        func appDidEnterBackground() {
            appIsActive = false
            guard isScanning, running == nil, graceTask == .invalid, lastProgress?.state != .paused
            else { return }
            graceTask = UIApplication.shared.beginBackgroundTask(withName: "iclean.scan") {
                [weak self] in
                Task { @MainActor in self?.gracePeriodExpired() }
            }
            trace("Grace period started")
        }

        func appWillEnterForeground() {
            appIsActive = true
            endGracePeriod()
            autoResumeIfDue()
        }

        // MARK: Continued processing task (iOS 26+)

        private func requestContinuation() {
            guard #available(iOS 26.0, *) else {
                allowance = .pausesOnLeave
                return
            }
            guard !submitting else { return }
            submitting = true
            Task {
                await submitContinuedTask()
                submitting = false
            }
        }

        @available(iOS 26.0, *)
        private func submitContinuedTask() async {
            // One handler per exact identifier, registered just before submitting; the
            // Info.plist permits the wildcard `com.mesbahtanvir.iclean.scan.*` (research R1).
            let identifier = Self.identifierPrefix + UUID().uuidString
            let registered = BGTaskScheduler.shared.register(
                forTaskWithIdentifier: identifier, using: .main
            ) { [weak self] task in
                MainActor.assumeIsolated {
                    self?.continuedTaskStarted(task, identifier: identifier)
                }
            }
            guard registered else {
                trace("Continued processing task could not be registered")
                allowance = .pausesOnLeave
                return
            }
            let (title, subtitle) = Self.text(for: lastProgress, device: Device.noun)
            // Submission can block briefly; keep it off the main thread.
            let failure: String? = await Task.detached {
                let request = BGContinuedProcessingTaskRequest(
                    identifier: identifier, title: title, subtitle: subtitle)
                request.strategy = .queue
                do {
                    if #available(iOS 27.0, *) {
                        try await BGTaskScheduler.shared.submitTaskRequest(request)
                    } else {
                        try BGTaskScheduler.shared.submit(request)
                    }
                    return nil
                } catch {
                    return String(describing: error)
                }
            }.value
            guard isScanning else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                return
            }
            if let failure {
                trace("Continued processing not available: \(failure)")
                allowance = .pausesOnLeave
            } else {
                queuedIdentifier = identifier
                allowance = .continues
                trace("Continued processing task submitted")
            }
        }

        @available(iOS 26.0, *)
        private func continuedTaskStarted(_ task: BGTask, identifier: String) {
            if queuedIdentifier == identifier { queuedIdentifier = nil }
            guard let task = task as? BGContinuedProcessingTask, isScanning, running == nil,
                !userPaused
            else {
                task.setTaskCompleted(success: true)
                return
            }
            let box = ContinuedTaskBox(task, device: Device.noun)
            running = box
            endGracePeriod()
            task.expirationHandler = { [weak self] in
                Task { @MainActor in self?.continuedTaskExpired(box) }
            }
            if let p = lastProgress { box.apply(p) }
            trace("Continued processing task started")
            // If the grace period already paused the scan, the task now covers it.
            autoResumeIfDue()
        }

        /// Fires for the user's Stop and for every system reason alike; both become a
        /// lossless pause that waits for the user (FR-006, FR-009).
        @available(iOS 26.0, *)
        private func continuedTaskExpired(_ box: ContinuedTaskBox) {
            guard running === box else { return }
            running = nil
            let scanner = self.scanner
            trace("Continued processing task expired; pausing")
            Task {
                await scanner?.pause(reason: .stoppedOutsideApp)
                box.complete(success: false)
            }
        }

        private func endContinuation(success: Bool) {
            if #available(iOS 26.0, *) {
                if let identifier = queuedIdentifier {
                    queuedIdentifier = nil
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                }
                if let box = running as? ContinuedTaskBox {
                    running = nil
                    box.complete(success: success)
                }
            }
            endGracePeriod()
        }

        // MARK: Grace period (all iOS)

        private func gracePeriodExpired() {
            guard graceTask != .invalid else { return }
            let identifier = graceTask
            graceTask = .invalid
            let scanner = self.scanner
            pendingAutoResume = true
            trace("Background time ran out; pausing")
            Task {
                await scanner?.pause(reason: .backgroundLimit)
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }

        private func endGracePeriod() {
            guard graceTask != .invalid else { return }
            UIApplication.shared.endBackgroundTask(graceTask)
            graceTask = .invalid
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
            /// `-TraceScan` mirrors the log to stdout so a scan can be watched from a Mac.
            private static let isTracing = ProcessInfo.processInfo.arguments.contains("-TraceScan")
        #endif

        // MARK: Text shown by the system (research R7)

        /// The words are the scan card's (`ScanningView`), so the Lock Screen and the app say one thing.
        /// `device` is `Device.noun`, read on the main actor by the caller: this runs off it.
        nonisolated static func text(for progress: ScanProgress?, device: String) -> (
            title: String, subtitle: String
        ) {
            let title = String(localized: "Scanning your library")
            guard let p = progress, p.total > 0 else {
                return (title, String(localized: "Starting…"))
            }
            if p.isThermalPaused {
                return (title, String(localized: "Paused to let your \(device) cool down"))
            }
            return (
                title,
                String(
                    localized: "\(p.processed.formatted()) of \(p.total.formatted()) checked")
            )
        }
    }

    /// Wraps the iOS 26 task so `ScanContinuation` can hold it in an `AnyObject` property.
    /// `BGTask` and `Progress` are safe to use from any thread, which is all this does.
    @available(iOS 26.0, *)
    private final class ContinuedTaskBox: @unchecked Sendable {
        let task: BGContinuedProcessingTask
        /// `Device.noun`, for the text the system shows.
        let device: String

        init(_ task: BGContinuedProcessingTask, device: String) {
            self.task = task
            self.device = device
        }

        func apply(_ p: ScanProgress) {
            let total = Int64(max(p.total, 1))
            task.progress.totalUnitCount = total
            task.progress.completedUnitCount = min(Int64(p.processed), total)
            let (title, subtitle) = ScanContinuation.text(for: p, device: device)
            task.updateTitle(title, subtitle: subtitle)
        }

        func complete(success: Bool) {
            task.setTaskCompleted(success: success)
        }
    }
#endif
