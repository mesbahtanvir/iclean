---

description: "Task list for Phased Cleaning for Large Libraries"
---

# Tasks: Phased Cleaning for Large Libraries

**Input**: Design documents from `/specs/004-phased-cleaning/`

**Tests**: Included; contracts/services.md lists guarantees G1 to G10 with their tests.

**Order**: stages S0 to S6 of the plan. Each stage ships on its own. Tasks marked [P] touch
different files and can run in parallel.

## Phase 1: Setup and measurement (S0)

- [X] T001 Spike S1: measure resident memory and time of loading 30,000 stored items with (a) `propertiesToFetch` without the blob columns, (b) external storage, (c) a separate blob entity. Record the numbers in `research.md` R4 and choose. *Done in 008 T003: a single `propertiesToFetch` fetch did not cap memory (609 MB); unsorted slices of 1,000 do (94 MB). Chosen: slices.*
- [ ] T002 Spike S2: extend `BaselineRunner` and `BaselineReport` to record preview fetch time, per-analyzer time, and items per second at widths 1, 2, 4, and 6. Run it on the author's phone and on the Mac. Replace the estimates in `research.md` R2 and R3.
- [X] T003 Promote `research-prototypes/bench30k` to a maintained Release benchmark (`Packages/CleanupKit/Benchmarks/ScaleBench`) that uses the package's own planner, index, and detectors instead of copies. Add `scripts/bench-scale.sh`. *Done in 008 T001 as `Packages/CleanupKit/Benchmarks/ScaleBench` (public API only).*
- [ ] T004 [P] Bound `SimilarShotsDetector` to at most 12 following neighbours per photo inside the 60 s window. Add `ScaleGuardTests.sameMinuteBurstIsBounded`. Re-run `DuplicateAccuracyTests` and the baseline bursts.
- [ ] T005 [P] Cap thumbprint confirmations per photo and in total in `DuplicatePhotoDetector` and `HashIndex`; skip near-constant fingerprints. Add `ScaleGuardTests.clusteredFingerprintsAreBounded`. *Partly in 008 T013: the confirmation is exact and about 40 times faster and pairs are streamed (281 s to 7 s for 27,700 look-alike photos); the caps are not built (008 T015).*
- [X] T006 [P] Add a 30,000-item scenario with optional per-item latency to `FakePhotoLibrary` and `DemoPhotoLibrary` (`-DemoScenario large30k`, `-DemoAnalysisLatencyMs`). *Done in 008 T002 for `DemoPhotoLibrary` (`large30k`, `-DemoAnalysisLatencyMs`); `FakePhotoLibrary` already has `previewDelay`.*
- [ ] T007 Spike S3: with a scan running on the phone, measure scroll smoothness in a category at width 4 and width 2. Decide the "user is reviewing" rule from the result.

## Phase 2: Foundational

- [ ] T010 Add `StepKind`, `CleaningPlan`, `ThrottleReason`, the new `ScanPauseReason` cases, and `ScanProgress.plan/throttle/blockCompleted` in `Models/Types.swift`.
- [ ] T011 Add the optional columns (`phase`, `block`, `signals`, `analysisVersion`, `featurePrintRevision`), `ResultsSnapshotRecord`, and the store revision to `Store/*`; implement in `SwiftDataStore` and `InMemoryStore`. Add a migration test against a store generated from the 003 schema.
- [ ] T012 [P] Split `Analyzer` into basic and deep stages and set `signals` accordingly; `Analysis.featurePrint` stays non-optional.
- [ ] T013 Create `Scanning/PhasePlanner.swift` and extend `ScanPlanner` with per-step eligibility from `signals`, newest-first ordering, the block ramp (500, 1,000, profile size), and the 60 s neighbour candidates. In the free app videos are never planned (Pro only, FR-004a).
- [X] T014 Videos are not analyzed in the free app (spec FR-004a; video analysis is a Pro feature, one-time $2, not built yet): ScanPipeline takes a ProFeatures switch (default free); a video gets no preview request and is stored with analysis source `metadataOnly`; the Duplicate Videos detector stays in the code but is only in `StandardPipeline.detectors(.pro)`; `ScanPlanner` re-plans `metadataOnly` videos on a full scan when Pro is on; `BaselineCatalog` is version 2 (`vid-dupA/B` became `vid-twin-1/2`, listed by size; check `videos.notAnalyzed` added; `videos.groups` and `videos.extras` removed); tests `VideosAreNotAnalyzedTests`; UI `DuplicateVideosFlowTests` runs with `-ProVideoAnalysis`. *Removed 2026-10-24: `ProFeatures`, `-ProVideoAnalysis`, `DuplicateVideoDetector` and `DuplicateVideosFlowTests` are gone with the Pro version (specs/016-free-photos-only/spec.md).*

## Phase 3: User Story 1 - The easy wins show up in seconds (P1)

- [ ] T020 [US1] Implement step 1 as one metadata enumeration without the album walk: screenshots final, large videos estimated then measured for the top 100. Publish to `AppModel` at once. *Partly in 008 T020: screenshots and free videos stored by the plan before any analysis; the album walk is not yet deferred.*
- [ ] T021 [US1] Move the album walk to a deferred background step; confirm by search that album names are display-only.
- [ ] T022 [US1] Tests `PhasedScanTests.quickWinsAreFinal` and `quickWinsNeedNoAnalysis`; UI test `testQuickWinsAppearBeforeAnalysis` with slow analysis.
- [ ] T023 [US1] Update the screenshot flow tests and the composition accuracy test for FR-003 (a duplicate screenshot no longer appears under Duplicates).
- [ ] T024 [US1] Home: the Cleanup plan list with the Quick wins row.

## Phase 4: User Story 2 - Review while the scan continues (P2)

- [ ] T030 [US2] Make `ScanPipeline` run steps 2 to 4 in order with phase-tagged chunks and emit `blockCompleted`; parameterize `DurableScanTests` by step (G5).
- [ ] T031 [US2] Create `Results/ResultsSnapshot.swift`; give the builder a continuity input; replace `AppModel.apply` with the merge rule and track explicit deselections (G3). *Partly in 008 T022: the builder is unchanged; 007's `ReviewIntent` carries the person's decisions over every rebuild (008 first used `ReviewChoices` and `ResultsContinuity`, replaced when the two were merged); the saved snapshot is 007.*
- [ ] T032 [US2] Frozen category lists and the "N new" prompt in `CategoryView`; keeper continuity. *Partly in 008 T022: results are held while a list is open and shown behind "N new results. Show"; only chosen keepers are carried over (008 Decision 1).*
- [ ] T033 [US2] "found so far, checked N of M" labels and the suppressed empty state (G4). *Partly in 008 T023: "Found so far · checked N of M" in the header and a "Looking for things" state; not on every row.*
- [ ] T034 [US2] Tests `PhasedScanTests.finalEqualsOneShot` over random block sizes and orders (G2) and `ReviewIntentTests`; newest-first resume.
- [ ] T035 [US2] UI test: open a category while a scan runs, toggle and change a keeper, wait for an update, check the list is unchanged and the prompt works.
- [ ] T036 [US2] Plan rows show live state; Recent Scans lists each step.

## Phase 5: User Story 3 - The pace fits the device and the moment (P3)

- [ ] T040 [US3] Create `Scanning/RunProfile.swift` with `DeviceCapabilities`, `Conditions`, `RunProfile`, and `runProfile()`; `RunProfileTests` table-driven with the monotonicity property and `previewSizeIsFixed` (G1, G10).
- [ ] T041 [US3] Create `Scanning/ScanGovernor.swift` with hysteresis on an injected `Clock`; `GovernorTests` for the thermal ramp.
- [ ] T042 [US3] Create `iclean/App/ConditionsProvider+iOS.swift` (thermal, Low Power, `UIDevice` battery, memory warnings, `os_proc_available_memory`) and the live `CapabilityProbe` (memory, cores, Neural Engine through `VNRequest`); fakes named by class.
- [ ] T043 [US3] Dynamic width in `ScanPipeline` (a bounded window in place of the fixed 4); chunk size from the profile; pause reasons `lowPower`, `waitingForPower`, `battery`, `memory` with automatic resume; `runNow`.
- [ ] T044 [US3] Fused versus deferred deep work by profile; step 3 only when deferred.
- [ ] T045 [US3] Time estimates as ranges from a moving average per step; store the measured speed for Settings.
- [ ] T046 [US3] Settings Scan speed; device-noun strings in the string catalog; `ScanningView` copy.
- [ ] T047 [US3] UI tests with `-iclean-device` and `-iclean-conditions` for the Scenario 3 table.
- [ ] T048 [US3] Amend the 002 thermal text and `ScanPipelineTests`: fair halves the width.

## Phase 6: User Story 4 - A 30,000-photo library stays fast on every launch (P4)

- [X] T050 [US4] Implement slim loading per T001: `slimItems()`, `blobs(for:)`, `BlobSource` in the builder; memory assertion. *Done in 008 T010/T012 as `itemSummaries`, `itemsWithoutFeaturePrints`, `featurePrints(for:)` and `ResultsLoader`.*
- [ ] T051 [US4] Saved snapshot and store revision; the launch path reads the snapshot; background refresh when the revision differs (G9).
- [ ] T052 [US4] Audit `category(of:)` and `group(containing:)` call sites and give them O(1) lookups.
- [ ] T053 [US4] Release tests for 30,000 and 100,000 items: time and peak memory, 3,000 same-minute photos, 15% clustered fingerprints (G8).
- [ ] T054 [US4] Debug-only log when a results build exceeds 5 s. *Not built; the `-TraceScan` log prints every rebuild.*
- [ ] T055 [US4] Only if T053 fails SC-004 or SC-005: the incremental results engine (stage S5). Otherwise record why it was not built.

## Phase 7: User Story 5 - Stop after a step and continue later (P5)

- [ ] T060 [US5] `stopAfterCurrentStep`, `continueFindingMore`, `notRun` and `stoppedAfter` states, the Home actions, and `PhasedScanTests.stopAndContinue` (G6).

## Phase 8: Polish

- [ ] T070 Update `README.md`, `INSTALL.md`, `docs/SCAN_PIPELINE.md`, and `docs/MATCHING_ROADMAP.md`.
- [ ] T071 Run `quickstart.md` on the phone and the Mac; record results in `validation-log.md`.
- [ ] T072 Accessibility audit of the plan list at the largest text sizes; update the allowlist only for system-capped elements.
- [ ] T073 Add a baseline check `phased.finalEqualsOneShot` and per-step timings to `BaselineValidator` and `BaselineReport`, so every device proves FR-014.
- [ ] T074 Lint the touched files, `scripts/check-no-network.sh`, the full package tests, and the UI suite.

## Dependencies

- Phase 1 first. T004 and T005 are independent and worth shipping alone.
- Phase 2 before any story. T013 needs T011 and T012; T014 can run first and alone.
- Phase 3 (S1) needs only T010 and T013; it can ship before Phase 4.
- Phase 4 (S2) needs Phase 3. Phase 5 (S3) needs Phase 4 for the plan list and block events.
- Phase 6 (S4) needs T001 and Phase 4; T055 is conditional on T053.
- Phase 7 needs Phase 4. Phase 8 last.
