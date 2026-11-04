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

## Screens (`iclean`, not compiled by CI)

- [X] T008 `TierRows.swift`: tier words, `TierRows`, `TierRow`, `TierGlyph`, `DeepOfferRow` (FR-014, FR-016).
- [X] T009 `AppModel`: `scanTier`, `deepRemaining`, `deepWait`, `hasDeepOwed`, `startDeepScan`; the owed count
  from the final event and from each quick check.
- [X] T010 `ScanningView` shows the tiers; `ResultsView` groups the finds by tier while a scan runs and shows
  the offer row; `HomeNothingToShow` says "Nothing found so far" when deep work is owed (FR-014, FR-015).
- [X] T011 `LaunchArguments.tiered`, `AppEnvironment`; Recent Scans and the Lock Screen text name the tier.
- [X] T012 `TieredScanUITests`: three tests, opting in with `-Tiered on`.

## Still to do (needs a Mac or a phone)

- [ ] T013 `xcodegen generate` and build the iOS app and the Mac app. Nothing under `iclean/` has been compiled.
- [ ] T014 Run the UI tests. Expect `TieredScanUITests` to need adjustments, and the one-pass tests to pass
  unchanged (tiers are off under `-UITesting` unless asked for).
- [ ] T015 Update the older UI tests for tiers (`results.foundSoFar`, "N of M checked") and make tiers the
  default under `-UITesting`.
- [ ] T016 Look at the screens in Dynamic Type at the accessibility sizes, VoiceOver, Dark Mode and Increase
  Contrast; the tier rows stack at accessibility sizes, which is untested.
- [ ] T017 Add a tiered mode to `ScaleBench` and time it against the one-pass scan on the Mac and on a phone.
  The deep check decodes a preview a second time for the photos it analyzes; whether the earlier cheap
  results are worth it is the number to measure (spec 010 measured 6.4 of 13 ms of Vision on a Mac).
- [ ] T018 Strings: the new text is not in `Localizable.xcstrings`; Xcode adds it on the first build.
- [ ] T019 Live Photos and Dark (015 Stories 2 and 4) when they land: `CleanupCategory.tier` already places
  them.
- [ ] T020 Decide whether the Mac sidebar and Overview should group by tier (Decision 7), and whether the
  battery rule (004 FR-019) is wanted.
