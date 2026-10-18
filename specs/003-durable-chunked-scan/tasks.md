---

description: "Task list for Durable Chunked Scan"
---

# Tasks: Durable Chunked Scan

**Input**: Design documents from `/specs/003-durable-chunked-scan/`

**Tests**: Included; contracts/services.md lists guarantees G1–G10 with their tests.

## Phase 1: Setup

- [X] T001 Add `ScanFailure`, `LibraryItem.scanFailure/scanAttempts`, `ScanSession.baseProcessed/failedItems/crashCount/interruptedCount`, `ScanProgress.failed` in `Packages/CleanupKit/Sources/CleanupKit/Models/Types.swift`.
- [X] T002 [P] Create `Packages/CleanupKit/Sources/CleanupKit/Models/ScanChunk.swift` (`ScanChunk`, `ScanChunkState`, `ScanRetryPolicy`).

## Phase 2: Foundational

- [X] T003 Create `Packages/CleanupKit/Sources/CleanupKit/Store/ScanChunkRecord.swift`; add optional columns to `ScanSessionRecord.swift` and `LibraryItemRecord.swift`.
- [X] T004 Extend `Store.swift` and `SwiftDataStore.swift`: `sessions`, `scanAttempts(for:)`, `createJob`, `chunks(job:)`, `saveChunks`, `checkpoint`, `deleteChunks`; prune and delete-all remove chunks.
- [X] T005 [P] Add `fetchItems(withIDs:)` to `PhotoLibrary.swift` (default) and `PhotoKitLibrary.swift`; implement in `FakePhotoLibrary` and `DemoPhotoLibrary`.
- [X] T006 [P] Create `Scanning/Timeout.swift`, `Scanning/ScanPlanner.swift`, `Scanning/ScanReclaim.swift`.

## Phase 3: User Story 1 - Survives anything, resumes from the middle (P1)

- [X] T007 [US1] Rewrite `Scanning/ScanPipeline.swift` as a chunk-driven loop: lease, run, checkpoint, release-before-wait, reclaim on load, legacy adoption, catch-up, finish.
- [X] T008 [US1] Tests `crashLosesOnlyTheChunkInFlight`, `resumeAfterPauseDoesNotRediffTheLibrary`, `progressNeverDecreasesAcrossResume`, `pauseReleasesTheChunkBeforeWaiting`, `quickCheckDoesNotTouchAnUnfinishedJob` in `Tests/CleanupKitTests/Unit/DurableScanTests.swift`; existing `ScanPipelineTests` updated to `chunkSize:`.

## Phase 4: User Story 2 - A problem photo never blocks the scan (P2)

- [X] T009 [US2] Reclaim rules (isolate → suspect → poison, crash budget) in `ScanReclaim.swift`; isolate mode and give-up path in `ScanPipeline.runChunk`.
- [X] T010 [US2] Tests `reclaimIsolatesThenSuspectsThenPoisons`, `reclaimLeavesReleasedChunksAlone`, `crashBudgetStopsTheJob`, `poisonedItemIsSkippedAndCounted`, `itemThatAlwaysFailsIsGivenUpOnAndTheRestFinishes`, `hungPreviewTimesOutInsteadOfStallingTheScan`.
- [X] T011 [US2] `FlakyAnalyzer` and `hangIDs` in `Tests/CleanupKitTests/Fakes/FakePhotoLibrary.swift`; `poison` scenario in `iclean/App/DemoPhotoLibrary.swift`.

## Phase 5: User Story 3 - Temporary problems retry themselves (P3)

- [X] T012 [US3] Backoff and `notBefore` scheduling with pause/stop-aware waiting in `ScanPipeline`; `scanAttempts` stamping; planner re-queues unanalyzed items on full scans while `< crossScanAttempts`.
- [X] T013 [US3] Tests `transientFailuresAreRetriedWithoutLoss`, `givenUpItemsAreRetriedOnLaterFullScansUpToALimit`.

## Phase 6: User Story 4 - The library changes between runs (P4)

- [X] T014 [US4] Deleted ids skipped in `runChunk`; `catchUp()` after an interruption.
- [X] T015 [US4] Tests `deletedItemsInAPendingChunkAreSkippedSilently`, `itemsAddedDuringAnInterruptionAreCaughtUp`.

## Phase 7: Polish

- [X] T016 `scan.failed` line in `iclean/Features/Scanning/ScanningView.swift`; Recent scans in `iclean/Features/Settings/SettingsView.swift` with `AppModel.recentSessions()`.
- [X] T017 Store tests `chunksRoundTripAndDeleteWithTheJob`, `sessionsAreListedNewestFirst`.
- [X] T018 Run `scripts/check-no-network.sh`, `scripts/lint.sh`, the full package tests, and the simulator UI test `testInterruptedScanResumesAfterRelaunch`.
- [ ] T019 Install on the iPhone over the existing store; run quickstart Scenario 2 (kill and resume) and Scenario 3 (hung item); record results in research R6. *Status 2026-10-17: built and installed; the launch and both scenarios are pending because the phone was locked. Run the two commands in quickstart Scenario 2 once it is unlocked.*

## Phase 8: Review fixes (2026-10-17 and 2026-10-18)

See [review-findings.md](review-findings.md) for the 18 defect groups, fixes and tests.

- [X] T020a Fix the three high-severity pause and resume defects and add their tests.
- [X] T020b Fix silent item skipping, crash blame, crash-budget recording, catch-up, atomic job end, store rollback, the quick-check race, and Delete All Data mid-scan.
- [X] T020c Add `-ChunkSize` (DEBUG) and strengthen `testInterruptedScanResumesAfterRelaunch`.
- [X] T020e Add `StoreMigrationTests` with a previous-schema store fixture; results in [validation-log.md](validation-log.md).
- [ ] T020d Run the on-device scenarios (quickstart scenarios 2 and 3) and the leave-the-app check with an unlocked phone. The same scenarios pass on the simulator (validation-log.md).

## Dependencies

Phase 1 → 2 → 3; Phases 4–6 build on the pipeline from Phase 3; Phase 7 last.
