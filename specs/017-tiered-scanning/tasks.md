# Tasks: 017 Tiered scanning

**Input**: [spec.md](spec.md). No separate plan: the design is the spec's tier table, and it reuses 010's skip
record and repair rule instead of adding a mechanism.

## Engine (`Packages/CleanupKit`)

- [X] T001 `ScanTier`, `CleanupCategory.tier`, `DeepWait`, `TierState`, `ScanTierStatus`
  (`Scanning/ScanTier.swift`) (FR-001, FR-013).
- [X] T002 `VisionWork.exact`; `DefaultAnalyzer` adds the Unimportant face pass only without it (FR-005).
- [X] T003 `ScanSession.tier` (optional column on `ScanSessionRecord`), `ScanProgress.tier` /
  `deepRemaining` / `deepWait`, `StoredItemSummary.sharpness` (FR-007, FR-009, FR-012).
- [X] T004 `ScanPlanner` scopes `.photos`, `.deep`, `.changes`; `.all` is every earlier scan. Burst frames
  listed early; a stored `metadataOnly` photo is planned again; the owed rule (FR-003 to FR-008, FR-011).
- [X] T005 `ScanPipeline(tiered:deepWait:)`: two durable jobs in one run, no final event between, `startDeepScan`
  (`Scanner` has a default), Low Power Mode wait (FR-009, FR-010).
- [X] T006 `TieredScanTests`: 19 tests (the last one run four ways), including equality with a one-shot scan on both profiles and a quick
  check that leaves the backlog alone (SC-001 to SC-005).
- [X] T007 CI on the pull request: package tests, lint, no-network check green.

## Screens (`iclean`, compiled by `app.yml`)

- [X] T008 `TierRows.swift`: tier words, `TierRows`, `TierRow`, `TierGlyph`, `DeepOfferRow` (FR-014, FR-016).
- [X] T009 `AppModel`: `scanTier`, `deepRemaining`, `deepWait`, `hasDeepOwed`, `startDeepScan`; the owed count
  from the final event and from each quick check.
- [X] T010 `ScanningView` shows the tiers; `ResultsView` groups the finds by tier while a scan runs and shows
  the offer row; `HomeNothingToShow` says "Nothing found so far" when deep work is owed (FR-014, FR-015).
- [X] T011 `LaunchArguments.tiered`, `AppEnvironment`; Recent Scans and the Lock Screen text name the tier.
- [X] T012 `TieredScanUITests`: three tests, opting in with `-Tiered on`.

## Tests added with the CI workflows (`docs/CI.md`)

- [X] T021 `PlannerPropertyTests`: 150 seeded random libraries and stores, every scope and kind against the
  definition worked out again in the test, and a tiered plan against a one-pass plan.
- [X] T022 `CrashPointTests`: a scan killed after every write it makes, in both modes, is finished the way Home
  leads the person and ends in the store and results an uninterrupted scan ends in, with no job left active and no
  work done twice. The sweep also requires that its kills really cut scans short, and that one landed between the
  photo check and the deep check, so it cannot pass by interrupting nothing (SC-005).
- [X] T023 `TierStatusTableTests`: `ScanTierStatus` over all 320 progress events an engine could report.
- [X] T024 `TierTextTests` and `HelperTests` in `icleanTests`: the words of every tier and state, no invented time,
  no claim that the library is clean while work is owed.
- [X] T025 `-LowPowerMode on` (DEBUG) and `testLowPowerModeHoldsTheDeepCheckBackAndRunNowStartsIt`: the deep check is
  held back, Home offers "Run Now" and says why, and running it finds what only it can find (FR-010, FR-015).
- [X] T026 The screenshot tour has frames of the tiers while a scan runs, of the finds grouped by tier, and of the
  offer; `ui-tests.yml` saves them as artifacts.

## Still to do (needs a Mac or a phone)

- [X] T013 `xcodegen generate` and build the iOS app and the Mac app. `app.yml` does it on every push (iPhone and
  Mac, Debug and Release, Xcode 26.6) and the built-app check passes. The screens compiled as written; the one
  error was an older line (`ScanContinuation.swift` calls the iOS 27 SDK's asynchronous `submitTaskRequest`),
  now compiled only by a Swift 6.4 or later compiler.
- [X] T014 Run the UI tests. `ui-tests.yml` runs them in four shards on an iPhone 17 Pro simulator (iOS 26.5):
  all pass, and the one-pass tests passed unchanged. `TieredScanUITests` needed one adjustment, to scroll to the
  later tier groups (a `List` holds only the rows near the screen); the Low Power Mode test passed first time.
  The NoNetwork plan passes (zero network requests in the full flow).
- [ ] T015 Update the older UI tests for tiers (`results.foundSoFar`, "N of M checked") and make tiers the
  default under `-UITesting`.
- [ ] T016 Look at the screens in Dynamic Type at the accessibility sizes, VoiceOver, Dark Mode and Increase
  Contrast. Partly covered by CI: at the largest text size the three tier rows are there and say "Ready" (a UI
  test), the tiers' flows pass in dark mode, and the screenshot tour saves frames of the tiers, the finds grouped
  by tier and the "Run Now" offer as artifacts. **No person has looked at them**, and VoiceOver and Increase
  Contrast are untested.
- [X] T017 `ScaleBench --tiered`, and `package-deep.yml` runs both scans of the same library with the real
  analyzer and requires equal digests. On a 3-core virtual Mac (600 synthetic items, phone profile): the photo
  check was done at 3.9 s (152 items/s), the whole tiered scan took 35.8 s, a one-pass scan 38.1 s, and the
  results and analysis digests were equal. So the second preview decode did not cost more than the cheap
  results saved here. **Not measured on a phone**, where decoding and Vision cost differently (spec 010 measured
  6.4 of 13 ms of Vision on a Mac).
- [ ] T018 Strings: the new text is not in `Localizable.xcstrings`; Xcode adds it on the first build.
- [ ] T019 Live Photos and Dark (015 Stories 2 and 4) when they land: `CleanupCategory.tier` already places
  them.
- [ ] T020 Decide whether the Mac sidebar and Overview should group by tier (Decision 7), and whether the
  battery rule (004 FR-019) is wanted.
