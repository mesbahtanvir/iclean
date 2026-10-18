# Research: Scan Progress Outside the App

Decisions for [plan.md](plan.md). Sources: iOS 27 SDK headers
(`BackgroundTasks.framework/Headers/BGTask.h`, `BGTaskRequest.h`, `BGTaskScheduler.h`),
Apple documentation for `BGContinuedProcessingTask`, and Apple Developer Forums thread
799126 (DTS answer on wildcard identifiers).

## R1. How to keep the scan running and show progress outside the app

- **Decision**: On iOS 26+ submit a `BGContinuedProcessingTaskRequest` when a full scan
  starts (and again on in-app Resume). iOS then keeps the app running after it leaves the
  foreground and *itself* shows the task "in a Live Activity" (Dynamic Island and Lock
  Screen) with the request's `title`/`subtitle` and the task's `progress`, plus a Stop
  control (BGTask.h: "Continued processing tasks will present UI while in progress";
  Apple docs: "The system displays the progress of this task in a Live Activity and a
  person can cancel it through the interface").
  - Identifier: `com.mesbahtanvir.iclean.scan.<UUID>` per scan. Info.plist
    `BGTaskSchedulerPermittedIdentifiers` lists the wildcard
    `com.mesbahtanvir.iclean.scan.*` (BGTaskRequest.h: "The identifier ought to use
    wildcard notation ... `<MainBundle>.<SemanticContext>.*`").
  - Registration: a launch handler is registered for the *exact* identifier right before
    submitting. Continued processing tasks are exempt from the register-before-launch
    rule (BGTaskScheduler.h), and DTS states that registering one handler for the
    wildcard pattern itself is blocked. Each identifier is registered once (a second
    registration of the same identifier kills the app), hence a fresh UUID per scan.
  - Strategy: `.queue` (default). If the system is busy the task starts later; the launch
    handler then resumes a scan that the grace period paused (see R2).
  - Progress: the task "must report progress via NSProgressReporting"; the app sets
    `progress.totalUnitCount` and `completedUnitCount` from every `ScanProgress`, and
    calls `updateTitle(_:subtitle:)` with "Scanning your library" / "N of M checked".
  - Expiration: `expirationHandler` fires for the user's Stop and for every system
    reason alike; they cannot be told apart (forum reports; same for `BGProcessingTask`).
    The handler pauses the scan with reason `.stoppedOutsideApp` (lossless) and then
    calls `setTaskCompleted(success: false)`. The scan stays paused until the user taps
    Resume (spec FR-009 second sentence).
  - Finishing: when the scan stream ends (completed or stopped) or the user pauses in the
    app, the task is completed with `setTaskCompleted(success: true)`, which removes the
    system display (FR-004, FR-011).
- **Rationale**: One system-provided display, no second process, no custom UI to keep in
  sync, and it is the only sanctioned way to get minutes of background CPU for a
  user-initiated job. It is also why the outside-app controls are limited to Stop.
- **Alternatives considered**:
  - *Custom Live Activity (ActivityKit + widget extension) with Pause/Resume/Stop
    buttons*: gives the exact controls the user named, but provides no background
    runtime, so the island would show "paused" 30 s after leaving the app; combining it
    with the continued processing task would put two activities for one scan in the
    island. Rejected.
  - *`BGProcessingTask`*: deferred, runs when the device is idle and charging; not
    "keep going now". Rejected (also rejected in 001 R10 for scheduled scans).
  - *Audio/location background modes*: misuse of background modes. Rejected.

## R2. Fallback when no continued processing task is running

- **Decision**: When the app enters the background with a scan running and no continued
  processing task is active (iOS 18–25, submission refused, task still queued, or
  simulator), call `UIApplication.shared.beginBackgroundTask(expirationHandler:)`. The
  scan keeps running for the grace period iOS grants (about 30 s). On expiration, pause
  the scan with reason `.backgroundLimit` and end the background task. On return to the
  foreground, a scan paused for `.backgroundLimit` resumes by itself (spec FR-009/FR-010).
  If a queued continued processing task starts while the scan is paused for
  `.backgroundLimit`, its launch handler resumes the scan.
- **`UIBackgroundModes`**: `processing` is added. The SDK lists "The app doesn't set the
  appropriate mode in UIBackgroundModes" as a cause of `BGTaskSchedulerErrorCodeNotPermitted`,
  and Apple's documentation for continued processing does not clearly exempt it. It is a
  scheduling permission, not a network entitlement (constitution Principle V unaffected).
  **Verified on device 2026-10-17** (iPhone 17 Pro, iOS 26.6.2): with the key present
  the task was granted at once and a 23-item demo scan ran to completion entirely in the
  background (progress 10/23, 20/23, 23/23 all logged after another app was in front).
  A build *without* the key has not been tried; drop the key only after such a test.
- **Rationale**: Same lossless-pause behaviour on every supported iOS, and a scan is never
  interrupted "for no reason" from the user's point of view.
- **Alternatives considered**: Pausing immediately on leaving the app (loses the free
  30 s and feels abrupt); not auto-resuming (the user did nothing to deserve a pause).

## R3. Where the pause reason lives

- **Decision**: `ScanPauseReason` (`user`, `stoppedOutsideApp`, `backgroundLimit`) is kept
  by the `ScanPipeline` actor and reported in `ScanProgress.pauseReason`. It is not
  persisted. After a relaunch, Home shows "Resume Scan" exactly as in 001, which already
  satisfies spec Story 3 scenario 4.
- **Rationale**: No SwiftData schema change, no migration, and the reason only matters
  while the process is alive (to decide auto-resume and the status text).
- **Alternatives considered**: Persisting it in `ScanSessionRecord` (needs a lightweight
  migration for no user-visible gain).

## R4. Progress granularity

- **Decision**: The pipeline now emits a `ScanProgress` every 10 processed items
  (`progressEvery`, new parameter) while still saving to the store every 100
  (`saveEvery`). Pausing for any reason flushes pending items first, so a paused scan
  is fully saved (FR-007).
- **Rationale**: The system progress bar and the in-app bar move about twice per second
  at the 001 performance target instead of every five seconds; the store write rate is
  unchanged.
- **Alternatives considered**: Lower `saveEvery` (more disk writes for nothing).

## R5. Testing strategy

- **Decision**:
  - `CleanupKit` unit tests (macOS, fast): pause reasons in progress, resume clears the
    reason, flush-on-pause leaves the store complete, `resumesOnForeground` rule,
    progress cadence.
  - XCUITest (simulator): the Scanning screen shows the "when you leave" line; backgrounding
    the app mid-scan (`XCUIDevice.shared.press(.home)`) and re-activating it leaves the
    scan running or auto-resumed, and results still appear. The simulator reports
    `BGTaskSchedulerErrorCodeUnavailable` ("running on Simulator which doesn't support
    background processing"), so this exercises the fallback path by construction.
  - On-device manual scenario in quickstart for the Dynamic Island, Stop, and Resume.
- **Rationale**: Everything deterministic is automated; the one thing that needs real
  hardware is listed as a manual step with expected outcomes.

## R6. Privacy check

- **Decision**: No change to `scripts/check-no-network.sh`; BackgroundTasks and UIKit
  background time do not match and must not. The NoNetwork UI test plan still runs the
  scan flow with networking disabled.
- **Rationale**: Principle V stays verifiable without new tooling.

## R7. Strings shown by the system

- **Decision**: Title "Scanning your library"; subtitle "N of M checked", or "Paused to
  let your iPhone cool down" during a thermal pause. No counts of duplicates or blurry
  photos, no asset names.
- **Rationale**: Progress only; nothing about the library's content is shown on the Lock
  Screen.
