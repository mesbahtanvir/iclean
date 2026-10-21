---

description: "Task list for Persistent Review Session"
---

# Tasks: Persistent Review Session

**Input**: Design documents from `/specs/007-persistent-session/`

**Tests**: Included; each phase lists its tests.

## Implementation status (2026-10-18)

Built in the working tree (not committed): the store foundation (revision, state rows, checksummed
snapshot with compare-and-swap, `setSizes`, `DeferredStore`, the newer-format refusal), the
snapshot, decisions and position logic with their tests, the debounced writer, the launch and publish
policy in `AppModel`, route restore with the attempt counter, the Continue row, "Saved on this
iPhone", `RemovalGate` and `RemovalPlan` with the "Checking your selection" sheet, the visible-set
check at launch (`AppModel.checkVisibleSet` over `PhotoLibrary.stamps(forIDs:)`, not a separate
`VisibleSetValidator`), the storage-failure pause (`ScanPauseReason.storageUnavailable`, unsaved
results carried to the next checkpoint, never "completed" with results unsaved), scroll to the last
touched photo, and a golden test that pins the builder output to `BuilderVersion`. Tests: package
unit tests, the kill-and-relaunch UI tests (`PersistentSessionTests`, a real kill on the simulator),
fault tests on damaged, truncated, newer-format and log-less stores.

Not built: T001 (shipped-store fixture), T002 (superseded notes), T003 and T004 (the 30,000 and
100,000 item benchmark, signposts, phone probes, `validation-log.md`), the inline "N photos were
removed or edited" note, the checks in batches of 1,000, the child-process crash-loop test (the UI
relaunch tests cover the kill instead), the slim planner input (T047), and everything that needs the
iPhone. Checkboxes below are left as written; this section is the current state.

**After every phase**: `swift test --package-path Packages/CleanupKit`, an `xcodebuild` for the
simulator **and** for the iPhone (the macOS package build skips iOS-only files), `xcodegen generate`
after adding files, and lint of the files touched only.

## Phase 0: Setup and baselines (stage S0)

- [ ] T001 Write `scripts/make-shipped-store-fixture.swift` (own process, in the style of `scripts/make-previous-store-fixture.swift`) and add `Packages/CleanupKit/Tests/CleanupKitTests/Fixtures/shipped-store`; extend `StoreMigrationTests` with `aStoreFromTheCurrentBuildOpensUnchanged` for both fixtures (it fails first if anything non-additive slips in).
- [ ] T002 [P] Add a "superseded" note to `docs/SCAN_PIPELINE.md` and `docs/APP_PLATFORM.md`: GRDB, an App Group container and a `commit_journal` table were never adopted; the shipped store is SwiftData in Application Support; the removal journal is replaced by specs/007.
- [ ] T003 [P] Promote `research-prototypes/bench30k` (004) to a maintained Release benchmark at 30,000 and 100,000 items; add Release `os_signpost` intervals for container open (with and without the migration) and for first content frame. Opt-in local test on a copy of the owner's real store (copy `.store`, `-wal` and `-shm` together with `devicectl`; never committed). Record phone numbers in `validation-log.md`.
- [ ] T004 [P] On-device probes, recorded in `validation-log.md` and research R17: bursts and hidden photos fetched by id (with and without options), `protectionKey` of the three store files after the first unlock, effective `PRAGMA synchronous` on the phone.

## Phase 1: Foundational: off-main store and store foundation (stage S1)

**Blocks every later phase. No new blocking store call ships before T005 and T006.**

- [ ] T005 `Store/DeferredStore.swift`: an actor conforming to `Store` that creates the `SwiftDataStore` (container, in-memory fallback, and the DEBUG `-PersistStore` and `-UITesting` paths) off the main thread; exposes the open status (`ready` or `volatile(reason)`) and an erase operation; `AppEnvironment.live()` stops using `try? SwiftDataStore.onDisk() ?? inMemory()`.
- [ ] T006 Main-thread assertion hook in the store methods (Debug builds); `DeferredStoreTests` (calls wait for the open; an open failure surfaces; no method runs on the main thread); run the UI suite with the hook on.
- [ ] T007 `Store/StoreMetaRecord.swift`, `Store/StateRecord.swift`, `Store/StateCodec.swift` (LZFSE of JSON, SHA-256, `StateKey`); add both entities to `SwiftDataStore.schema`.
- [ ] T008 Extend `Store.swift` and `SwiftDataStore.swift`: results-projection compare in `put()`, the revision rule (data-model table), `resultInputs()`, `revision()`, `loadLaunchState()`, `saveState`, `deleteState`, `stateInfo`, `saveSnapshot(ifRevision:)`, `setSizes` (existing rows only, one bump per batch), `sizes(for:)`; `deleteAllData()` covers state rows and moves the revision on without reusing a number.
- [ ] T009 [P] Tests: `ResultsRevisionTests` (a table over every mutating method stating bump or no bump: new row, changed metadata, album order only, identical re-upsert, `analyzedAt` or `scanAttempts` or byte-size-only change, `deleteItems`, `setKeep` add, remove and clear, `checkpoint` with new items, `setSizes` from none or estimated to measured and from measured to measured, session and chunk writes, `deleteAllData` never reusing a number); `StateRecordTests` (round trip; a byte flip and a truncation give nothing and delete the row; an unknown version gives nothing; Delete All empties them); `StoreCommitTests` (`saveSnapshot` refuses on a moved revision; a failed write rolls back).
- [ ] T010 Dev-only `CrashHarness` executable target in `Package.swift` (macOS) and `CrashLoopTests`: 100 SIGKILLs at seeded random offsets during checkpoint, decision and snapshot writes and during open; after each, an integrity check on a copy of the trio, decisions equal to the previous or next generation, the snapshot absent or passing its gate, and the 003 chunk invariants.

## Phase 2: User Story 4 - Problems with the saved data are explained, not hidden (P4, stage S2)

**Goal**: no interim build can hide a failure to open, a failed read or a failed scan write.

**Independent Test**: damage a copy of the store in each way in quickstart Scenario 2 and fill the disk.

- [ ] T011 [US4] `Store/StoreOpenFailure.swift`: classify open failures (data not yet available, damaged, newer format, migration failure); `DeferredStore` waits out "not yet available" and retries when protected data becomes available; the rest give the volatile state. No quarantine; damaged files are left untouched.
- [ ] T012 [US4] `AppModel`: the volatile state and the "Progress won't be saved this time" line on Home; replace every `try?` read that becomes `[]` (items, keep marks, launch reads) with a load-failure state in Home and Results; never "Your library looks clean" on an error.
- [ ] T013 [US4] `ScanPipeline`: count consecutive checkpoint, chunk and session write failures; at 3 pause with `ScanPauseReason.storageUnavailable` (in memory only); resume after recovery; `ScanningView` copy "Couldn't save progress. Free up space, then tap Resume."
- [ ] T014 [US4] Settings: "Delete saved data" row (shown when the store could not be opened or read), confirmation dialog, removes `.store`, `-wal` and `-shm` together through the `DeferredStore` erase, then opens an empty store (asking for a reopen is acceptable in v1).
- [ ] T015 [P] [US4] Tests: `FaultInjectionTests` on a copy of the trio (zero header, truncate, flip an interior byte, delete the `-wal`, newer-format store, damaged and wrong-version payloads, wrong builder key; outcomes in quickstart Scenario 2); `ScanWriteFailureTests` with a failing `Store` wrapper (pause after 3, resume after recovery, nothing marked saved that was not); classification tests (4618 is waited out, never reported as damage); a UI test for the volatile notice (a DEBUG argument forces an open failure).

## Phase 3: User Story 1 - Back where I was, with my choices (P1, stage S3)

**Goal**: ticks and keeper choices survive a kill and a foreground return.

**Independent Test**: tick, choose a keeper, wait 3 s, kill, relaunch; compare.

- [ ] T016 [US1] `Results/ReviewIntent.swift`: the decisions payload, the recording rules (event-sourced, normalized after every change), and the pure applier (keeper choices in `decidedAt` order, defaults recomputed from the groups, `forcedOn` validity with 7-day expiry, `forcedOff` and keeper choices 180 days).
- [ ] T017 [US1] `Results/ReviewSession.swift`: the pure reducer lifted from `AppModel` (toggle, bulk select, `makeKeeper`, removed, adopt); `ResultsBuilder.swift`: recompute the default selection after `removing()`; route every `removing()` call (visible-set check, observer, removal, Always keep) through the applier.
- [ ] T018 [US1] `Store/ReviewStateWriter.swift`: single-writer actor; trailing debounce 500 ms with a 2 s maximum wait; coalescing; awaited `flush()`; retry after a failure; generation counter and `invalidate()`.
- [ ] T019 [US1] `AppModel` and `icleanApp`: `apply()` uses the applier (no more `selection = defaultSelection`); a foreground return no longer resets; handle `.inactive` and `.background` with `UIApplication.beginBackgroundTask` called synchronously in the handler and ended when the flush completes (a helper next to `ScanContinuation`, whose "only type using UIKit background time" comment is updated: the flush cannot remove photos); flush when the confirm sheet opens and before a removal.
- [ ] T020 [US1] Delete All Data order in `AppModel`: bump the writer generation and cancel pending writes; clear in-memory choices, path, pending results and any in-flight reconcile; `store.deleteAllData()`; refuse flushes from older generations.
- [ ] T021 [P] [US1] Tests: `ReviewIntentTests` (an applier table with every row of the data-model table, and an override applying to a rebuilt group with a new id); `ReviewSessionTests` (property tests: selection is a subset of members; `apply(apply(x)) == apply(x)`; toggle then Keep This One sequences; a relaunch equals the session); `ReviewStateWriterTests` (manual clock: coalescing, ordering, flush awaits an in-flight write, retry, refusal of an older generation); a Delete All Data test (tick, Delete All, background, relaunch: zero state rows, with and without a pending debounce).
- [ ] T022 [US1] `icleanUITests/PersistenceTests.swift`: `testSelectionSurvivesKill`, `testKeeperChoiceSurvivesKill`, `testSelectionSurvivesForegroundReload` (run through `xcodebuild`, so `terminate()` is a real SIGKILL).

## Phase 4: User Story 3 - A stale view can never delete the wrong photo (P3, stage S4)

**Goal**: removal executes exactly a checked plan. **Ships before any snapshot (Phase 5).**

**Independent Test**: quickstart Scenario 4.

- [ ] T023 [US3] `PhotoLibrary.stamps(for:)` (modification date, favorite, existence; an absent id means not in the library) and one `PHFetchOptions` factory used by `fetchAllItems`, `fetchItems(withIDs:)` and `stamps`; `FakePhotoLibrary.stamps`.
- [ ] T024 [US3] `Removal/RemovalPlan.swift` and the gate in `Remover.swift`: drop photos not returned, favorites now and photos changed since they were suggested, and any group in which none of the photos the plan would keep is still in the library (unless the person chose the whole group under 001 FR-016); a second check inside `remove`.
- [ ] T025 [US3] `ConfirmSheet`: flush the writer and build the plan when the sheet opens; "Checking selection" with Remove disabled until the gate returns; show the count left out; Remove executes exactly the plan; results are not swapped while a sheet is open.
- [ ] T026 [P] [US3] Tests: `RemovalGateTests` (deleted, edited, favorite now, burst member present, keeper vanished, whole-group choice); UI `testKilledInsideConfirmSheetRelaunchesWithoutSheet` and `testKillDuringRemovalReconciles` (a DEBUG argument that keeps the demo library's deletions across launches).
- [ ] T027 [US3] Device check from T004: burst frames pass the gate and the options factory on the phone. Record the result before this phase ships.

## Phase 5: User Story 2 - Results appear at once and are never stale (P2, stage S5)

**Goal**: saved results restore without a rebuild, only when they match.

**Independent Test**: relaunch after a scan with nothing changed, then change the library, the rules and the bytes one at a time.

- [ ] T028 [US2] `Results/ResultsSnapshot.swift`: the slim payload, header, `BuilderKey`, `BuilderVersion`, `CleanupResults.slimmed()`, encode, and the gate (`SnapshotRestore`: checksum, format, builder key, revision, counts, age).
- [ ] T029 [US2] A golden-output test over the baseline library that fails if builder output changes without raising `BuilderVersion`; a build-twice-gives-identical-output test.
- [ ] T030 [US2] `Scanning/SizeMeasurer.swift`: call `setSizes` instead of upserting items taken from results (blobs must survive); overlay measured sizes from the store by id on restored results.
- [ ] T031 [US2] `AppModel`: `resultsBasis`, the publish rules, `pendingResults`; no patch-forward after a removal or Always keep (the revision moves, the lists update in place through the applier, a normal off-main rebuild follows, compare-and-set save); snapshot save after a rebuild and again after a size batch moved the revision; the "Clear saved results" action.
- [ ] T032 [P] [US2] Tests: `ResultsSnapshotTests` (encode then decode equals `slimmed()`; the recomputed default selection equals the builder's; a validation matrix: each header field flipped, a byte flip, truncation, newer format, another time zone, another access level, count mismatch, an 8-day-old snapshot); `SizeMeasurerTests` (thumbprint, feature print and hash survive); UI `testRelaunchShowsResultsWithoutRescan`.
- [ ] T033 [US2] Release benchmark at 30,000 and 100,000 photos: snapshot bytes, decode time, resident MB after a restore and after a rebuild. Record in `validation-log.md` and research R17.

## Phase 6: User Story 2 - The launch path (P2, stage S6)

**Goal**: first frame never claims more than is known; reconcile is quiet and never reshuffles.

- [ ] T034 [US2] `LaunchPhase` (`opening`, `building`, `ready`, `failed`); placeholders in `HomeView` and `ResultsView`; "Preparing your library" after 400 ms; no "Scan Library" and no "Your library looks clean" before `ready`.
- [ ] T035 [US2] The launch sequence in `AppModel.onLaunch`: `loadLaunchState`; the off-main gate, decode and applier; one publish; the cold path (plan, step 6); `onForeground` ignored until `ready`; the `.active` at launch joins the launch reconcile; no unconditional `reloadResults()`.
- [ ] T036 [US2] `Scanning/VisibleSetValidator.swift` (pure) and the reconcile: single-flight; the visible-set check in batches of 1,000 with the inline note; `quickCheck()` (skipped while a removal commit is in flight or an interrupted scan has its own catch-up); the "Checking for changes" row after 300 ms; `PhotoKitLibrary.beginObserving()` (register and a lazy baseline without enumerating).
- [ ] T037 [P] [US2] Tests: `LaunchPlannerTests` (a decision table: snapshot used, or rebuild with the reason); `ReconcileTests` (manual clock: gone and changed ids dropped, single-flight, skipped while removing or interrupted); cold-start UI tests; Release device signposts to the first content frame and the cost of the quick check (this decides research R13 and R14).

## Phase 7: User Story 1 - Saved place (P1, stage S7)

**Goal**: the same screen after a kill, within 24 hours; the Continue row after that.

- [ ] T038 [US1] `Results/ReviewPosition.swift`: `Route`, `ReviewPosition`, `RouteValidator`, and the restore counter rules (write +1 before restoring; reset by a clean flush or after 30 s; skip at 2).
- [ ] T039 [US1] Navigation: `NavigationStack(path:)` bound to a typed `[Route]` held as scene-local state in the root view and mirrored into the breadcrumb; value-based links (the Group link becomes a route; Settings is not saved); `GroupDetailView` takes anchors and resolves the live group; a loading state in `CategoryView` and `GroupDetailView` while building; scroll to the last photo touched; restore with animations off so the first content frame is the restored screen; a DEBUG `-CrashOnRestore` argument.
- [ ] T040 [US1] The "Continue reviewing" row on Home (what, ticked count, space, how long ago) and "Start fresh" behind a confirmation; going Home on purpose writes an empty path.
- [ ] T041 [P] [US1] Tests: `RouteValidatorTests` (category empty falls back to Home; group dissolved falls back to the category; an anchor moved to another group; anchor gone but the group alive); UI `testRestoresCategoryAfterKill` (foreground kill, and background first), `testGroupDissolvedFallsBackToCategory`, `testCrashDuringRestoreFallsBackToHome`, `testRelaunchLandsOnNonModalScreenAfterKillInConfirmSheet`; update the `AccessibilityTests` allowlist for any new Settings row.

## Phase 8: User Story 4 - Saved on this iPhone (P4, stage S8)

- [ ] T042 [US4] `iclean/Features/Settings/SavedDataView.swift` behind one constant row at the end of Settings: saved results (size, when built), review progress (counts), saved place; read from the saved rows, not from file attributes; "Clear saved results" (deletes the row; results rebuild); "Reset review choices" (clears decisions and position through the writer generation; keeps scan data and Always keep marks); a pointer to Delete All Data.
- [ ] T043 [P] [US4] Tests: inventory counts and sizes; Clear saved results then relaunch rebuilds; Reset clears decisions and position only; Delete All leaves zero state rows; `testDeleteAllData` extended to relaunch and see nothing restored; the `AccessibilityTests` audit with the new row allowlisted in `systemCapped`; confirm `PrivacyInfo.xcprivacy` needs no new reason.

## Phase 9: Polish and validation (stage S9)

- [ ] T044 Run `scripts/check-no-network.sh`, lint of the touched files, the full package tests, `xcodegen generate`, an `xcodebuild` for the simulator and for the iPhone, and the whole UI suite including `PersistenceTests`.
- [ ] T045 Review the 2026-10-18 notes in `specs/004-phased-cleaning/data-model.md` and `plan.md` against what shipped (snapshot record, store revision, seen-groups) and fix any difference.
- [ ] T046 Run quickstart Scenarios 5 and 8 on the iPhone over the real store and record the results in `validation-log.md` (new file); replace the "target" marks in spec.md and the unmeasured rows of research R17 with measured numbers.
- [ ] T047 With the owner, from the measurements: decide the slim planner input (004 FR-025), the change-token delta (research R13), an app build stamp in the builder key, and an open-format export of keep marks and choices (constitution IV). Record the decisions in plan.md.

## Deferred (not in this feature, no tasks)

- The change-token delta for the quick check, built only if the foreground reconcile costs more than
  about 1.5 s or 300 MB at 30,000 photos on the phone (research R13).
- `VersionedSchema` adoption, at the first non-additive change, with a verified fixture.
- A JSON copy of Always keep marks or salvaging a damaged store.
- A screen to review and undo single Always keep marks.
- The incremental results engine of 004 S5.

## Dependencies

Phase 0 and Phase 1 first (T005 and T006 before any new store call). Phase 2 after Phase 1. Phase 3
after Phase 1. Phase 4 after Phase 3 (the plan uses the flushed writer) and **before** Phase 5. Phase 5
after Phase 4. Phase 6 after Phase 5. Phase 7 after Phase 6 (it validates routes against published
results and needs the loading states). Phase 8 after Phases 3 and 5. Phase 9 last.
