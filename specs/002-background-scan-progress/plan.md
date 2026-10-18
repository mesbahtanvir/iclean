# Implementation Plan: Scan Progress Outside the App

**Branch**: `002-background-scan-progress` | **Date**: 2026-10-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/002-background-scan-progress/spec.md`

## Summary

Keep a user-started full scan running after the user leaves the app, show its progress
in the Dynamic Island and on the Lock Screen, let the user stop it from there without
losing work, and make every system-initiated interruption a safe pause. On iOS 26 and
later the app submits a *continued processing task* (`BGContinuedProcessingTask`,
BackgroundTasks framework): iOS keeps the app running after it leaves the foreground and
draws the progress itself as a system Live Activity with a Stop control; the app only
feeds it a title, a subtitle, and an `NSProgress`. Expiration of that task, whether from
the user's Stop or from the system, pauses the scan losslessly. On older iOS, or when the
task is refused, the app uses the ordinary short background grace period
(`UIApplication.beginBackgroundTask`), pauses when it expires, and resumes by itself on
return. No custom Live Activity, no widget extension, no new dependency, no network
(see [research.md](research.md)).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK

**Primary Dependencies**: Apple frameworks only. New in this feature: BackgroundTasks
(`BGTaskScheduler`, `BGContinuedProcessingTaskRequest`, `BGContinuedProcessingTask`,
iOS 26+) and UIKit's `beginBackgroundTask` (all iOS). No third-party code.

**Storage**: unchanged SwiftData store. The pause reason is in-memory only (research
R3); no schema change.

**Testing**: Swift Testing for the pipeline changes (`CleanupKit`), XCUITest for the
Scanning screen states and the leave-and-return flow on the simulator, on-device manual
check for the Dynamic Island (quickstart Scenario 3; the simulator has no background
task scheduler, research R5), static no-network script unchanged.

**Target Platform**: iOS 18.0+ iPhone only (unchanged). Background continuation and the
outside-app progress display need iOS 26+ (`#available`); iOS 18–25 get the fallback
(spec FR-010).

**Project Type**: mobile-app (single iOS app + one local Swift package), unchanged

**Performance Goals**: unchanged (≥ 20 items/s). Outside-app progress updates at least
every 100 items (FR-002); progress events now every 10 items so the system bar moves
smoothly (research R4).

**Constraints**: zero network; previews only; one scan at a time; pause within 5 s of
expiration (FR-007); nothing removed by any background path (FR-014, FR-015).

**Scale/Scope**: 1 new app file, 2 CleanupKit files touched, 1 screen touched, 2 Info.plist
keys. No new screens.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Gate | Pre-research | Post-design |
|-----------|------|:------------:|:-----------:|
| I. Local-Only Data | No new data leaves the device; nothing new is stored | ✅ | ✅ R3: pause reason in memory only |
| II. No Outbound Network | BackgroundTasks is not a networking API; the app still has no network code | ✅ | ✅ R6; `check-no-network.sh` unchanged and still passes |
| III. Offline-Safe Dependencies | No third-party dependency added | ✅ | ✅ Apple system frameworks only |
| IV. User Owns Their Data | Background work never removes anything; Stop outside the app is a pause | ✅ | ✅ FR-014/FR-015; services contract guarantee G5 |
| V. Verifiable Privacy | Static script unchanged; no network entitlement; `UIBackgroundModes` gains `processing`, which is not network-related | ✅ | ✅ R2; quickstart Scenario 1 |
| Data Handling Constraints | Logs on device via `os.Logger`; no temp files | ✅ | ✅ |
| Workflow gate | "Data & Network" statement below | ✅ | ✅ |

**Result**: PASS. No violations; Complexity Tracking not needed.

### Data & Network statement (required by constitution workflow)

- **Data touched**: the same previews and metadata as 001, now also while the app is in
  the background. New in-memory state: why the scan paused, whether a background
  allowance is active. Nothing new is written to disk.
- **Shown outside the app**: the system progress display gets only the app name, the
  text "N of M checked", and a fraction. No asset identifiers, names, or images.
- **Where stored**: unchanged (Application Support, excluded from backup).
- **Network**: none. The continued processing task permits background CPU "and network
  access" at the system level, but the app contains no networking code; the static check
  and the NoNetwork UI test plan stay in CI. `UIBackgroundModes: processing` is a
  scheduling permission, not a network entitlement.

## Project Structure

### Documentation (this feature)

```text
specs/002-background-scan-progress/
├── plan.md              # This file
├── research.md          # Phase 0: decisions R1–R7
├── data-model.md        # Phase 1: ScanSession pause reason, allowance states
├── quickstart.md        # Phase 1: validation scenarios
├── contracts/
│   ├── services.md      # Scanner protocol delta + guarantees
│   └── ui.md            # Scanning screen states and accessibility ids
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
project.yml                                   # + BGTaskSchedulerPermittedIdentifiers, UIBackgroundModes
iclean/Info.plist                             # regenerated by xcodegen from project.yml
iclean/App/
├── icleanApp.swift                           # scenePhase → continuation hooks
├── AppModel.swift                            # pause reason, auto-resume, continuation wiring
└── ScanContinuation.swift                    # NEW: BGContinuedProcessingTask + grace-period fallback
iclean/Features/Scanning/ScanningView.swift   # new states + "when you leave" line

Packages/CleanupKit/Sources/CleanupKit/
├── Models/Types.swift                        # ScanPauseReason, ScanProgress.pauseReason
└── Scanning/ScanPipeline.swift               # pause(reason:), flush on pause, progressEvery
Packages/CleanupKit/Tests/CleanupKitTests/Unit/ScanPipelineTests.swift

icleanUITests/BackgroundScanTests.swift       # NEW: screen states, leave and return
```

**Structure Decision**: same two-module layout as 001. Everything that does not need
UIKit or BackgroundTasks (pause reasons, flush-on-pause, the auto-resume rule) lives in
`CleanupKit` so it is unit-tested on macOS. The one new app file owns all BackgroundTasks
and UIKit background-time calls so they are easy to audit.

## Risks & open items

- **`UIBackgroundModes: processing` may not be required** for continued processing tasks
  (Apple's docs are ambiguous; research R2). It is included because `notPermitted` lists
  a missing background mode as a cause. Verify on device; remove if a build without it
  still gets the task.
- **User Stop vs. system expiration are indistinguishable** (research R1). Both are
  treated as "stopped outside the app": stay paused, offer Resume (spec FR-009).
- **System may expire a stalled task**: a thermal pause in the background reports no
  progress and may be expired. Handled as above.
- **Queued task starting late**: with the `.queue` strategy the task may start after the
  grace period already paused the scan; the launch handler resumes it (research R1).

## Complexity Tracking

No constitution violations to justify.
