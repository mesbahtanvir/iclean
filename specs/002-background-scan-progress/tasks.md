---

description: "Task list for Scan Progress Outside the App"
---

# Tasks: Scan Progress Outside the App

**Input**: Design documents from `/specs/002-background-scan-progress/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/services.md,
contracts/ui.md, quickstart.md

**Tests**: Included. contracts/services.md lists guarantees G1–G4 that each need a unit
test, and the constitution (Principle V) requires the no-network checks to keep passing.

**Organization**: Tasks are grouped by user story so each story can be built, tested,
and shipped on its own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on unfinished tasks)
- **[Story]**: Which user story the task belongs to (US1–US4)

## Path Conventions

- `iclean/`: SwiftUI app target (screens and wiring; the only place BackgroundTasks and
  UIKit background time may be used)
- `Packages/CleanupKit/Sources/CleanupKit/`: all logic (paths always written in full)
- `Packages/CleanupKit/Tests/CleanupKitTests/`: unit tests
- `icleanUITests/`: XCUITest flows

## Rules that apply to every task

- No networking APIs anywhere; `scripts/check-no-network.sh` must pass (constitution V).
- No third-party dependencies. Apple frameworks only.
- Nothing in scanning or continuation code may call `PhotoLibrary.remove` (guarantee G5).
- Every new UI text gets the accessibility identifier from contracts/ui.md, VoiceOver
  support, and Dynamic Type.

---

## Phase 1: Setup

**Purpose**: Declare the background task identifier and mode

- [X] T001 In `project.yml` add to the `iclean` target's `info.properties`:
  `BGTaskSchedulerPermittedIdentifiers: ["com.mesbahtanvir.iclean.scan.*"]` and
  `UIBackgroundModes: [processing]` (research R1, R2); run `xcodegen generate` and
  confirm `iclean/Info.plist` now contains both keys.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Pause reasons, lossless pause, and progress cadence in CleanupKit. Every
story depends on these.

- [X] T002 In `Packages/CleanupKit/Sources/CleanupKit/Models/Types.swift` add
  `public enum ScanPauseReason: String, Sendable, Codable { case user, stoppedOutsideApp, backgroundLimit }`,
  add `public var pauseReason: ScanPauseReason?` to `ScanProgress` (init default nil;
  "non-nil only while state == .paused"), and
  `public var resumesOnForeground: Bool { state == .paused && pauseReason == .backgroundLimit }`.
- [X] T003 In `Packages/CleanupKit/Sources/CleanupKit/Scanning/ScanPipeline.swift`:
  change the `Scanner` protocol to `func pause(reason: ScanPauseReason) async`; keep the
  reason in the actor and report it from `snapshot()` while paused; clear it in `resume()`;
  add `progressEvery: Int = 10` to `init` and emit a progress event at least every
  `progressEvery` processed items (store writes still every `saveEvery`); before waiting
  while paused or too hot, flush pending items and save the session, then set a
  `pausedAndSaved` flag that `pause(reason:)` waits for (up to 2 s) before returning
  (G1, FR-007).
- [X] T004 In `Packages/CleanupKit/Tests/CleanupKitTests/Unit/ScanPipelineTests.swift`
  update `pauseAndResume` to `pause(reason: .user)` and add tests for G1 (after a pause the
  store holds exactly `processed` items and the session is `paused`; resuming finishes
  the scan), G2 (`pauseReason` reported while paused and nil after resume), G3
  (`resumesOnForeground` true only for `.backgroundLimit`), and G4 (with
  `progressEvery: 5`, consecutive events never differ by more than 5 processed items).
- [X] T005 Run `swift test --package-path Packages/CleanupKit --filter ScanPipelineTests`
  and `scripts/lint.sh`; fix until green.

---

## Phase 3: User Story 1 - Watch the scan from anywhere on the phone (Priority: P1) 🎯 MVP

**Goal**: A user-started scan keeps running after the user leaves the app, and iOS shows
its progress in the Dynamic Island and on the Lock Screen.

**Independent Test**: quickstart Scenario 3 steps 1–3 on an iPhone running iOS 26+.

- [X] T006 [US1] Create `iclean/App/ScanContinuation.swift`: `@MainActor @Observable final class ScanContinuation`
  with `enum Allowance { case unknown, continues, pausesOnLeave }` and
  `private(set) var allowance`. `scanStarted(scanner:)`: on iOS 26+ build the identifier
  `com.mesbahtanvir.iclean.scan.<UUID>`, register a launch handler for that exact
  identifier on the main queue, then submit a `BGContinuedProcessingTaskRequest` (title
  "Scanning your library", subtitle "Starting…", strategy `.queue`) off the main thread;
  set `allowance` to `.continues` on success, `.pausesOnLeave` on any error or on iOS < 26.
  When the launch handler fires: if no scan is running, complete the task at once;
  otherwise keep it, set `progress.totalUnitCount`, and end any grace period (research R1).
- [X] T007 [US1] In `iclean/App/ScanContinuation.swift` add `update(_ progress: ScanProgress)`
  (sets `completedUnitCount`/`totalUnitCount` and calls `updateTitle("Scanning your library", subtitle: "N of M checked")`,
  or the thermal text from research R7) and `scanEnded()` (completes the task with
  success, cancels a still-queued request, ends any grace period, resets `allowance`).
- [X] T008 [US1] In `iclean/App/AppModel.swift` own `let continuation = ScanContinuation()`;
  in `startScan()` call `continuation.scanStarted(scanner:)` before the stream, call
  `continuation.update(p)` for every progress value, and `continuation.scanEnded()` when
  the stream ends; change `pauseScan()` to `pause(reason: .user)`.
- [X] T009 [US1] In `iclean/Features/Scanning/ScanningView.swift` add
  `.accessibilityIdentifier("scan.status")` to the headline and a footnote with id
  `scan.whenYouLeave` shown only while running: "Keeps scanning while you use other apps.
  Progress shows in the Dynamic Island and on the Lock Screen." for `.continues`,
  "Pauses when you leave iclean and continues when you come back." for `.pausesOnLeave`,
  hidden for `.unknown` (contracts/ui.md).

**Checkpoint**: Build and install on the iPhone; leaving the app during a scan shows
progress in the Dynamic Island that keeps rising until the scan completes.

---

## Phase 4: User Story 2 - Stop the scan from outside the app, resume later (Priority: P2)

**Goal**: Stop in the system display is a lossless pause; Resume in the app continues.

**Independent Test**: quickstart Scenario 3 step 4.

- [X] T010 [US2] In `iclean/App/ScanContinuation.swift` set the task's
  `expirationHandler` to pause the scan with `.stoppedOutsideApp` and then call
  `setTaskCompleted(success: false)`; capture only Sendable values in the handler.
- [X] T011 [US2] In `iclean/App/ScanContinuation.swift` add `scanPausedByUser()`
  (complete the task, cancel a queued request, end any grace period; FR-011) and
  `scanResumedByUser()` (submit a fresh task with a new identifier on iOS 26+); call
  them from `pauseScan()` / `resumeScan()` in `iclean/App/AppModel.swift`.
- [X] T012 [US2] In `iclean/Features/Scanning/ScanningView.swift` show the headline
  "Stopped from outside iclean" when `pauseReason == .stoppedOutsideApp` (Resume and
  Stop buttons as for any pause).

---

## Phase 5: User Story 3 - The phone can end the scan at any time, nothing is lost (Priority: P3)

**Goal**: Grace-period fallback with automatic resume; interrupted sessions still resume.

**Independent Test**: quickstart Scenario 2 (simulator) and Scenario 3 step 5, Scenario 4.

- [X] T013 [US3] In `iclean/App/ScanContinuation.swift` add `appDidEnterBackground()`:
  if a scan is running and no continued processing task is active, call
  `UIApplication.shared.beginBackgroundTask(withName:expirationHandler:)`; on expiration
  pause the scan with `.backgroundLimit` and end the background task. Add
  `appWillEnterForeground()` that ends an open background task. When a queued continued
  processing task starts while the scan is paused for `.backgroundLimit`, resume it
  (research R2).
- [X] T014 [US3] In `iclean/App/icleanApp.swift` call `model.onBackground()` when
  `scenePhase` becomes `.background`; in `iclean/App/AppModel.swift` add `onBackground()`
  (forwards to the continuation) and in `onForeground()` first forward to the
  continuation, then if `isScanning && progress?.resumesOnForeground == true` call
  `resumeScan()` (FR-009) before the existing quick-check logic.
- [X] T015 [US3] In `iclean/Features/Scanning/ScanningView.swift` show the headline
  "Paused while you were away" when `pauseReason == .backgroundLimit`.
- [X] T016 [US3] Create `icleanUITests/BackgroundScanTests.swift`:
  `testScanningScreenSaysWhatHappensWhenYouLeave` (start a scan in the `slow` scenario,
  assert `scan.whenYouLeave` exists) and `testLeavingAndReturningKeepsTheScanGoing`
  (start a scan, `XCUIDevice.shared.press(.home)`, wait 3 s, `app.activate()`, assert
  the scan is still running or results appear, then assert
  `results.category.duplicates` appears within 90 s).

---

## Phase 6: User Story 4 - iclean only ever suggests (Priority: P4)

**Goal**: Prove that background scanning removes nothing.

**Independent Test**: after a leave-and-return scan, every known demo item still exists.

- [X] T017 [US4] In `icleanUITests/BackgroundScanTests.swift` extend
  `testLeavingAndReturningKeepsTheScanGoing`: open the Duplicates category and assert
  `category.item.dup1-a` and `category.item.dup1-b` both exist (nothing removed, FR-015).
- [X] T018 [P] [US4] Review `iclean/App/ScanContinuation.swift` and
  `Packages/CleanupKit/Sources/CleanupKit/Scanning/ScanPipeline.swift` and confirm neither
  references `remove(`; note the result in the PR description (G5).

---

## Phase 7: Polish & Cross-Cutting Concerns

- [X] T019 Run `scripts/check-no-network.sh`, `scripts/lint.sh`,
  `swift test --package-path Packages/CleanupKit --skip AccuracyTests`, and
  `xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:icleanUITests/BackgroundScanTests`.
- [X] T020 Build for the connected iPhone, install, and run quickstart Scenario 3 steps
  1–2 (task granted, progress rising while the app is in the background); record the
  result and whether `UIBackgroundModes: processing` was needed in `specs/002-background-scan-progress/research.md` R2.
- [X] T021 [P] Add one line to `README.md` describing that a scan keeps running after you
  leave the app with progress in the Dynamic Island, and that Stop there never loses work.

---

## Dependencies & Execution Order

- Phase 1 and Phase 2 first (T001 is independent of T002–T005).
- US1 (T006–T009) depends on Phase 2. US2 (T010–T012) and US3 (T013–T016) depend on
  US1's `ScanContinuation` file. US4 (T017–T018) depends on US3's UI test.
- Within a story, tasks touching the same file run in order; `[P]` tasks may run with
  anything.

## Parallel Example

- After T003: T004 (tests) and T001 (plist) in parallel.
- After T009: T010/T011 (continuation) and T012 (view) in parallel; T018 and T021 any time.

## Implementation Strategy

- **MVP** = Phase 1 + Phase 2 + US1: the scan continues in the background with system
  progress, and expiration already pauses losslessly because `pause(reason:)` exists.
- Then US2 and US3 complete the controls and the fallback; US4 is verification.
