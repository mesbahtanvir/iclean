# Implementation Plan: iclean on Every Apple Platform with iCloud Photos

**Branch**: `005-all-apple-platforms` | **Date**: 2026-10-18 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/005-all-apple-platforms/spec.md`

## Summary

About 93% of the non-test source is already platform-neutral. The work is the 7% that is not,
plus layout. The package lowers its Mac floor to macOS 15 and adds visionOS 2, and the one real
photo-library implementation stops being iOS-only. The scan's way of staying alive moves behind
a small interface: the existing continuation stays on iPhone and iPad, the Mac gets process
activity, sleep and wake handling, and a Dock indicator, and the headset uses the existing grace
period. Home becomes a split view, review gains a focus separate from the removal mark and a
keyboard and pointer model, and windows are made safe to open more than once. A multi-platform
project, a Mac sandbox with no network entitlement, a build matrix in CI, and the baseline
library on every platform make the result checkable. Delivery starts with the CI matrix, because
CI compiles none of the app today.

The design follows the portability, platform, and capability research (see
[research.md](research.md)). Every compile claim below was checked in a scratch copy by the
research; the repository was not changed by it.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK; macOS 15 and visionOS 2
deployment floors

**Primary Dependencies**: unchanged (SwiftData, PhotoKit, Vision). The Mac adds IOKit power-source
notifications and AppKit for the Dock tile and the sleep and wake observers, all system frameworks.

**Storage**: unchanged. The store stays per device. File protection stays on iOS and visionOS; the
Mac relies on its sandbox container and FileVault and keeps the backup exclusion.

**Testing**: Swift Testing for new pure logic (the keep-alive with injected providers, review
focus and range rules); XCUITest per platform with per-platform audit sets; build jobs for iOS,
macOS, and visionOS; the baseline library run on each platform.

**Target Platform**: iOS and iPadOS 18, macOS 15 (Apple silicon), visionOS 2 (compatible)

**Project Type**: multi-platform app (one app target, one local Swift package)

**Performance Goals**: SC-007 on a Mac (estimate; measured with the baseline harness)

**Constraints**: no network permission on Mac; Apple silicon only (`ARCHS=arm64` for macOS);
no tvOS, watchOS, or Catalyst; one scan and one removal at a time across windows

**Scale/Scope**: 34 files named by the research; about 650 platform-specific lines after the
work (88 to 90% shared); 4 new source files, 2 new plists and entitlements, new icons

## Constitution Check

| Principle | Status |
|---|---|
| I. Local-only data | Pass. The store stays per device; no cross-device sharing (FR-006). |
| II. No outbound network | Pass, and stronger on Mac: the sandbox has no network entitlement, so the system blocks it. |
| III. Offline-safe dependencies | Pass. System frameworks only. |
| IV. User owns their data | Pass. Delete All Data and confirmation are unchanged on every platform. |
| V. Verifiable privacy | Pass. `check-no-network.sh` also checks the Mac entitlements file and the extra network patterns. |

### Data & Network statement

New data: none. Power source and sleep state are read in memory. The Mac entitlements are the
sandbox and the Photos library permission only. Network access: none, enforced by the system on
Mac.

## Design

### D1. Package and build gates

- `platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)]`. The floor is set by the Vision Swift
  requests (macOS 15, iOS 18, visionOS 2). A scratch build with macOS 15 produced a universal
  library, so macOS 26 is not required.
- `PhotoKitLibrary` and `LongExposure` move from `#if os(iOS)` to `#if canImport(Photos)`. UIKit
  is imported only where it exists; the AppKit image converts with
  `cgImage(forProposedRect:context:hints:)`. Without this, a Mac or headset build compiles but
  contains no real library, which CI would not notice.
- `SwiftDataStore.prepare` file protection: `#if os(iOS) || os(visionOS)`.
- Do not add tvOS or watchOS to `platforms`.

### D2. One interface for staying alive

```swift
@MainActor protocol ScanKeepAlive {
    var allowance: Allowance { get }     // continues | pausesOnLeave | runsWhileOpen | unknown
    func scanStarted(), scanEnded(), scanPausedByUser(), scanResumedByUser()
    func update(progress:)               // for the system progress or the Dock
    var onAutoResume: (() -> Void)? { get set }
}
```

| Platform | Implementation | Behaviour |
|---|---|---|
| iPhone, iPad | existing `ScanContinuation` (file kept, guarded `#if os(iOS)`) | continued task on iOS 26 or later; grace period and resume otherwise |
| Mac | `ScanKeepAlive+macOS` (new) | `ProcessInfo.beginActivity` (user-initiated, automatic and sudden termination disabled) held only while scanning; `NSWorkspace` will-sleep pauses and did-wake resumes; low power and power source feed 004's conditions; the app delegate keeps the app alive after the last window closes while scanning, and pauses on terminate; the Dock tile shows progress |
| Vision Pro (compatible) | the grace-period helper | scene inactive or background maps to the existing background-limit pause |

The iOS and Mac keep-alives share the pause reasons of 002 and 004. New reasons `systemSleep`
(Mac) and `windowClosed` (headset) are automatic and resume on their own. The grace-period code
moves into a small shared helper. A compatible iPad app on Vision Pro may still reach the
continued-task code at run time; that path must fall back without an error (spike S2).

### D3. Project, entitlements, Info, icons, strings

- `project.yml`: `supportedDestinations: [iOS, macOS]` for the app target with
  `TARGETED_DEVICE_FAMILY: "1,2"`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO` (so the iPad build
  is not offered on Mac), and `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: YES` (the compatible
  Vision Pro run). `ARCHS[sdk=macosx*]: arm64`, hardened runtime on, per-SDK `INFOPLIST_FILE` and
  `CODE_SIGN_ENTITLEMENTS`. The UI test target gets the same destinations. Native visionOS is a
  later addition: the package already builds for it. One agent verified that this generates and
  builds in a scratch copy; re-verify (task T020).
- `iclean-macOS.entitlements`: App Sandbox and the Photos library permission, nothing else. In
  particular no `network.client` or `network.server`.
- Info: iOS and iPadOS keep the background keys; add iPad orientations
  (`UISupportedInterfaceOrientations~ipad`, all four), landscape for iPhone if wanted, and scene
  support for several windows. The Mac plist has no UIKit keys and adds the minimum system version
  and category. `PrivacyInfo.xcprivacy` is shared.
- Icons: a macOS icon set (or one layered icon); nothing is needed for compatible visionOS.
- Strings: device variations in `Localizable.xcstrings` for words that name the device or the
  background behaviour, and `InfoPlist.xcstrings` for the Photos permission text. The research
  found the words "iPhone", "Dynamic Island and Lock Screen", and "iOS will ask you to confirm" in
  the app.

### D4. Layout, review, and windows

- **Home** becomes a `NavigationSplitView`: sidebar with the plan (004) and categories, content
  with the category, detail with a group or inspector. It collapses to a stack on iPhone. All
  accessibility identifiers stay. Toolbar items use `.primaryAction` and not `.topBarTrailing`,
  which does not exist on Mac.
- **Review focus versus removal mark.** `model.selection` stays the removal marks. A per-window
  observable holds the focused photo and the range anchor. Click focuses, the check mark toggles,
  Shift-click marks a range from the anchor, Command-click toggles, Command-A marks all removable,
  Space toggles the focused photo, arrows move focus, Return opens it, Delete opens the sheet. A
  keeper is never marked by range or select-all. A context menu (View, Keep This One, Always Keep,
  Mark the rest) replaces the long press. Touch keeps tap to toggle. Targets are enlarged on the
  headset (the 24 pt view button is too small for gaze).
- **Group view** sizes columns from the container, requests pixels from the size and display
  scale (up to 2,048 on Mac), shares zoom between members, and opens in its own window.
- **Viewer** uses placements that exist on Mac; Escape closes, arrows move, Space toggles.
- **Confirm sheet** drops the iOS-only title mode on Mac, gets a form sizing, keeps Cancel on
  Escape, and gives Remove no default action so Return cannot delete.
- **Windows.** `AppModel.onLaunch` becomes idempotent; foreground and background are handled once
  at app level; a `removalInFlight` flag stops two windows removing at once. Scenes added: a Mac
  Settings scene, commands (Scan, Pause, Select All, Remove Selected through the sheet), a compare
  window and a viewer window, and window sizing.
- **Thumbnails** request pixels from cell size and scale, with a small cache and prefetch inside
  the library layer (no network).
- `DebugSeeding` (changes favorites) refuses to run on a Mac unless `-AllowRealLibrary` is given.

### D5. Pace per platform

Spec 004's run profile applies as is. Platform signals feed its conditions: `UIDevice` battery on
iPhone, iPad, and visionOS (unknown counts as battery); IOKit power source on Mac with a desktop
treated as mains; thermal and Low Power Mode everywhere; `os_proc_available_memory` on iOS and
visionOS and a memory-pressure source on Mac. The seed for a Mac with 16 GB or more is the "max"
profile; a fanless Air is held in check by the thermal rules. The headset gets one thermal step
cooler. Intel is excluded by architecture, not detected at run time.

### D6. Testing

- New pure tests: the Mac keep-alive with an injected activity provider and notification stubs for
  sleep, wake, and power changes; review-focus and range rules; the "never mark a keeper" rule.
- UI tests: `goBack` and `select(category:)` helpers by identifier, replacing about 8 taps on the
  navigation bar's back button (a split view has none); `.toggleStyle(.switch)` or checkbox
  queries on Mac; `XCUIDevice.shared.press(.home)` tests guarded to iOS; keyboard and pointer
  tests; a two-window test; layout tests on iPad orientations and Mac window sizes.
- Per-platform audit sets and test plans. macOS UI tests need signing and accessibility permission
  and are flaky on hosted runners, so they run nightly or by hand.
- `scripts/run-baseline.sh` gains a `mac` mode that launches the Mac build with `-BaselineRun` and
  requires `-AllowRealLibrary`, because the baseline writes into the system library. Use a spare
  macOS user or a virtual machine.

### D7. CI

Jobs: generate the project; build the app for the iOS Simulator, macOS (no signing), and the
package for iOS and visionOS; pin the Xcode version so the visionOS SDK exists; run the package
tests on macOS as today; nightly, the UI suite on an iPad simulator and the package tests on a
visionOS simulator; a check that the macOS entitlements have no network key.

## Project Structure

### Documentation (this feature)

```text
specs/005-all-apple-platforms/
├── spec.md
├── plan.md
├── research.md
├── quickstart.md
├── tasks.md
└── checklists/requirements.md
```

No data model or contracts file: this feature adds no stored data and no service contract beyond
the `ScanKeepAlive` interface above.

### Source Code (repository root)

```text
Packages/CleanupKit/
├── Package.swift                      # platforms
└── Sources/CleanupKit/{Library,Store,Models}   # gates, protection, pause reasons
iclean/
├── App/ScanKeepAlive.swift            # new: protocol and Allowance
├── App/ScanContinuation.swift         # changed: iOS only, conforms to ScanKeepAlive
├── App/ScanKeepAlive+macOS.swift      # new
├── App/ScanGracePeriod.swift          # new: shared helper (iOS below 26, visionOS)
├── App/MacShell.swift                 # new: Settings scene, commands, delegate adaptor
├── App/icleanApp.swift, AppModel.swift, AppEnvironment.swift, DebugSeeding.swift  # changed
├── Features/**                        # layout, toolbar, selection, viewer, confirm
├── iclean-macOS.entitlements          # new
├── Info.plist, Info-macOS.plist       # split
└── Resources/                         # icons, string variations
project.yml, .github/workflows/ci.yml, scripts/*, icleanUITests/*
```

## Delivery stages

| Stage | Contents | Exit |
|---|---|---|
| S0 | CI build matrix; package platforms and `canImport(Photos)` gates; hardware checks listed in research R6 | All platforms compile in CI; hardware answers recorded |
| S1 | iPad: device family, orientations, scenes, adaptive layout, string variations, audit | SC-001, SC-008 on iPad |
| S2 | Mac shell: compile fixes, Settings scene, commands, entitlements, plist, icon, keep-alive, Dock | SC-003, SC-004, SC-005 |
| S3 | Vision Pro compatible run: verify on simulator and headset, fallback without error | Story 3 scenarios |
| S4 | Split view home, review focus, keyboard and pointer model, group and viewer windows | SC-006 |
| S5 | Baseline library on every platform, comparison, performance on Mac | SC-002, SC-007 |

Stages S2 and later use 004's run profile when it exists and a fixed profile until then.

## Risks & open items

- Delete confirmation and Recently Deleted are not stated in the headers. They are documented
  behaviour on iOS and must be checked on a real Mac and a headset before release (FR-008).
- Mac PhotoKit shows only the System Photo Library. A user with another library sees nothing; the
  app must say so (FR-007). Behaviour under limited access on Mac and visionOS is not
  header-verifiable and needs hardware checks.
- Video file sizes under the Mac sandbox: `requestAVAsset` file URLs may not be readable, which
  degrades Large Videos to estimates. Checked in S0; only that list is affected, since videos are
  not analyzed in the free app (video analysis is a Pro feature).
- Vision feature-print revisions and preview decoding differ by OS version and platform. The
  duplicate thresholds were calibrated on an iPhone. The baseline library and the accuracy suites
  must run on Mac and visionOS, and the revision is recorded per item (004 data model).
- A compatible iPad app on Vision Pro may reach the continued-task code at run time although the
  native visionOS SDK marks it unavailable. A test on the simulator and a headset decides if a
  guard is needed.
- Power signals on Vision Pro (battery state) and Mac (IOKit on every model) are unverified on
  hardware; unknown is treated as battery, which is safe but can delay optional steps.
- Per-window state: sheets and navigation are per-window while the model is shared. Idempotent
  launch, app-level lifecycle, and `removalInFlight` are needed before multiple windows are enabled.
- Keyboard shortcuts near a destructive action: nothing may remove without the sheet; tests
  assert it (SC-006).
- App Store work outside the code: icons, per-platform screenshots, notarization, and review of
  cleaner apps. Distribution as one listing needs the identifier setup to be right the first time.
- `docs/APP_PLATFORM.md` is a stale earlier design (iOS 16, GRDB, StoreKit); it is marked
  superseded in T062 so nobody plans from it.

## Complexity Tracking

| Added piece | Why it is needed | Simpler option rejected |
|---|---|---|
| `ScanKeepAlive` interface | Mac, iPad, and headset stay alive in three different ways | `#if` blocks in the scan code: untestable and spreads platform code |
| Review focus separate from marks | Keyboard focus and "marked for removal" are different things; one set would remove what was only focused | Reuse the selection set: a Space or arrow could mark by accident |
| Native Mac app, not Catalyst | Catalyst has no background tasks or live progress and gives a worse Mac app | Mac Catalyst: cheaper, but the research rejected it |
| Compatible visionOS first | Native layout and gaze targets are a separate piece of work | Native visionOS now |
