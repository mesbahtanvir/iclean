---

description: "Task list for iclean on Every Apple Platform with iCloud Photos"
---

# Tasks: iclean on Every Apple Platform with iCloud Photos

**Input**: Design documents from `/specs/005-all-apple-platforms/`

**Tests**: Included for the pure logic (keep-alive, focus and range rules) and per platform for
the UI; hardware checks are listed in `research.md` R6.

**Order**: stages S0 to S5 of the plan. [P] marks tasks on different files.

## Phase 1: Setup and gates (S0)

- [ ] T001 Add a CI workflow job matrix: generate the project; build the app for the iOS Simulator and for macOS with `CODE_SIGNING_ALLOWED=NO`; build the package for iOS and visionOS; pin the Xcode version in `.github/workflows/ci.yml`.
- [ ] T002 Set `platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)]` in `Packages/CleanupKit/Package.swift`; confirm `swift test` and `swift build --build-tests` still pass on the macOS host.
- [ ] T003 [P] Change `PhotoKitLibrary.swift` and `LongExposure.swift` to `#if canImport(Photos)` (and widen the `addedDate` check to `#available(iOS 26.0, macOS 26.0, visionOS 26.0, *)`); import UIKit or AppKit conditionally; convert `NSImage` to `CGImage`; `SwiftDataStore.prepare` protection `#if os(iOS) || os(visionOS)`.
- [ ] T004 [P] Hardware checks from `research.md` R6 items 1 to 6 and 8: record each answer in `research.md` and amend this plan where one is negative.
- [ ] T005 [P] Add `ScanPauseReason` cases `systemSleep` and `windowClosed` (automatic, resumable) in `Models/Types.swift`.

## Phase 2: iPad (S1, User Story 1)

- [ ] T010 [US1] `project.yml`: `TARGETED_DEVICE_FAMILY "1,2"`, `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD NO`, `SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD YES`.
- [ ] T011 [US1] `Info.plist`: iPad orientations (all four), scene manifest with multiple scenes.
- [ ] T012 [US1] Make `AppModel.onLaunch` idempotent; handle foreground and background once at app level; add `removalInFlight` (FR-018).
- [ ] T013 [US1] `HomeView` as a `NavigationSplitView` with the plan and categories in the sidebar; `.primaryAction` toolbar placements; keep every accessibility identifier.
- [ ] T014 [P] [US1] `CategoryView`, `GroupDetailView`, `PhotoViewer`, `ConfirmSheet`: container-relative sizes, pixels from size and display scale, `.sheet` instead of `fullScreenCover` where needed, sheet sizing, no default action on Remove.
- [ ] T015 [P] [US1] `Thumbnail.swift`: pixel size from cell size and scale; small cache and prefetch in the library layer.
- [ ] T016 [P] [US1] String variations for iPhone, iPad, Mac, and Apple Vision Pro in `Localizable.xcstrings`; `InfoPlist.xcstrings` for the Photos permission text; fix `ScanningView`, `SettingsView`, `AccessView`, and `ConfirmSheet` copy.
- [ ] T017 [US1] UI tests: `goBack(app)` and `select(category:)` helpers in `UITestHelpers.swift` by identifier; replace about 8 back-button taps in 5 files; iPad orientation and Split View layout tests.
- [ ] T018 [US1] Per-platform accessibility audit sets and allowlists; run on iPad.
- [ ] T019 [US1] Guard `BackgroundScanTests` to iOS; add an iPad run to the nightly CI job.
- [ ] T020 [US1] Re-verify that `supportedDestinations`, the two `SUPPORTS_*` settings, and the device family generate and build together in `xcodegen`.

## Phase 3: Mac (S2, User Story 2)

- [ ] T030 [US2] Create `iclean/App/ScanKeepAlive.swift` (protocol, `Allowance`); make `ScanContinuation` iOS-only and conform; move the grace-period code to `ScanGracePeriod.swift`; `AppModel` owns `any ScanKeepAlive` from `AppEnvironment`.
- [ ] T031 [US2] Create `ScanKeepAlive+macOS.swift`: activity assertion held only while scanning; will-sleep and did-wake; power state and source into 004's conditions; Dock tile progress; unit tests with an injected activity provider and notification stubs.
- [ ] T032 [US2] Create `MacShell.swift`: delegate adaptor (keep running after the last window while scanning, pause on terminate); Settings scene; commands for Scan, Pause, Select All, Remove Selected through the sheet; window sizing.
- [ ] T033 [US2] `project.yml`: add the macOS destination, `ARCHS[sdk=macosx*]=arm64`, hardened runtime, per-SDK `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS`.
- [ ] T034 [US2] Create `iclean/iclean-macOS.entitlements` (sandbox and Photos library only) and `Info-macOS.plist` (no UIKit keys, minimum system version, category).
- [ ] T035 [P] [US2] Fix the compile errors found by the research: `AccessView` settings URL helper, `CategoryView` and `HomeView` toolbar placements, `PhotoViewer` placements, navigation-bar title mode in `RecentScansView` and `ConfirmSheet`.
- [ ] T036 [P] [US2] Mac icon set or a layered icon.
- [ ] T037 [US2] Guard `DebugSeeding` on Mac behind `-AllowRealLibrary`.
- [ ] T038 [US2] Explain in the access screen when macOS exposes no library or only the system library (FR-007).
- [ ] T039 [US2] `.toggleStyle(.switch)` on the group toggles so UI queries match on Mac; a Mac test plan and a nightly job.
- [ ] T040 [US2] `scripts/check-no-network.sh`: fail if the macOS entitlements file has a network key; add `NSURLSession`, `NWPathMonitor`, and `SystemConfiguration` patterns.
- [ ] T041 [US2] Mac test with the network entitlement absent: scan, review, and remove complete (R4).

## Phase 4: Vision Pro in compatibility mode (S3, User Story 3)

- [ ] T050 [US3] Run the iPad build on a visionOS simulator; confirm launch, scan, window-close pause, resume, and removal with confirmation.
- [ ] T051 [US3] Map scene inactive or background to the pause reasons; make the continued-task path fall back without an error if it is reachable.
- [ ] T052 [US3] Headset wording from the string variations; one thermal step cooler in 004's profile for head-worn devices.
- [ ] T053 [US3] On a headset when available: delete confirmation, battery state, and the checks in R6.

## Phase 5: Review on large screens (S4)

- [ ] T060 Add a per-window observable for focus and range anchor; keep `model.selection` as removal marks.
- [ ] T061 Implement click, Shift-click, Command-click, Command-A, Space, arrows, Return, Delete (opens the sheet only), and the context menu; never mark a keeper through range or select-all; tests for SC-006.
- [ ] T062 Update `README.md`, `INSTALL.md`, and mark `docs/APP_PLATFORM.md` as superseded.
- [ ] T063 Synchronised zoom and keyboard in the group view; compare and viewer as their own windows through `openWindow`.
- [ ] T064 Two-window tests: one scan, one launch, one removal confirmation.
- [ ] T065 Headset hit targets of about 60 pt for the view button and the Remove bar.

## Phase 6: Baseline on every platform (S5, User Story 4)

- [ ] T070 [US4] Add a `mac` mode to `scripts/run-baseline.sh` requiring `--allow-real-library`; record the platform and OS in the report (already in the device facts).
- [ ] T071 [US4] Run the baseline on an iPhone, an iPad, a Mac, and a visionOS simulator; compare with `scripts/compare-baseline-reports.py`; explain every difference in `docs/BASELINE_LIBRARY.md`.
- [ ] T072 [US4] Measure a 30,000-photo scan on an Apple-silicon Mac for SC-007 with the 004 harness.
- [ ] T073 [US4] Run the accuracy suites on a Mac and on a visionOS simulator; record the Vision revision per item (004 data model).

## Dependencies

- Phase 1 first; T001 before everything else that changes the app.
- Phase 2 before Phase 5 (the split view and per-window state); Phase 3 needs T003 and T030.
- Phase 4 needs T030. Phase 6 needs Phases 2 and 3. T041 needs T034.
- Spec 004's run profile is used when it exists; a fixed profile until then.
