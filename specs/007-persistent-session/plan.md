# Implementation Plan: Persistent Review Session

**Branch**: `007-persistent-session` | **Date**: 2026-10-18 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/007-persistent-session/spec.md`

## Summary

The scan is already a saved job (003). This feature saves the rest of the session: the results, the
person's choices, and the screen they were on. Everything lives in the one existing SwiftData
store, so a power-loss rollback can never leave the parts disagreeing.

Five layers, one direction of flow. **A** the analysis store stays the only source of truth for
derived data (unchanged tables). **B** a small meta row holds `resultsRevision`, a counter that only
goes up and moves in the same transaction as any write that changes what results are built from.
**C** the results snapshot is one checksummed, compressed row that is a disposable cache: shown only
when its checksum, format, builder key, revision and counts all match. **D** the person's review
choices are event-sourced overrides keyed by photo (never by group), replayed by one pure applier on
every publish, so a rebuild or a foreground return never resets them. **E** the screen they were on
is a typed route stack with a restore-attempts counter, restored on its own within 24 hours and
offered as a "Continue reviewing" row after that.

Because a snapshot makes the view older, removal safety ships first: opening the confirm sheet
builds an immutable plan after a commit-time freshness check against Photos, and Remove executes
exactly that plan. Nothing patches a snapshot forward after a removal: the revision moves, the
lists update in place for feedback, and a normal off-main rebuild is applied at the next Home visit
and saved with a compare-and-set.

The root cause of the "frozen screen" part of the problem is that the store is created on the main
thread, and an `@ModelActor` created there runs every method there (probed). The store is therefore
opened and created off the main thread by a `DeferredStore` before any new store work lands. An
open failure becomes a visible state ("Progress won't be saved this time"), never an empty or clean
library, and damaged files are never touched automatically.

The design came from a research workflow (five briefs) and a hostile review of it (17 objections).
Fifteen were adopted and two (a slim planner input, and an app build stamp in the builder key) were
not; see [research.md](research.md), "What the hostile review changed".

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK, deployment target iOS 18.0

**Primary Dependencies**: unchanged (SwiftData, PhotoKit). System frameworks used for the first
time: CryptoKit (SHA-256) and Foundation's LZFSE compression. No third-party dependency.

**Storage**: two new SwiftData entities, `StoreMetaRecord` and `StateRecord`, in the same store. The
four existing entities (`LibraryItemRecord`, `KeepMarkRecord`, `ScanSessionRecord`,
`ScanChunkRecord`) are not changed, so SwiftData's lightweight migration applies (003 R6). No
`VersionedSchema` is adopted now (research R12). See [data-model.md](data-model.md).

**Testing**: Swift Testing in `CleanupKit`: a table over every mutating store method (bump or no
bump), applier tables, snapshot round trip and corruption cases, a main-thread assertion hook, fault
injection on a copy of the store, a child-process crash loop (dev-only `CrashHarness` target, macOS),
removal-gate tests, reconcile tests with a manual clock. XCUITest `PersistenceTests` through
`xcodebuild` (so `terminate()` is a real SIGKILL). Release benchmarks at 30,000 and 100,000 items.
On-device soak. See [quickstart.md](quickstart.md).

**Target Platform**: iOS 18.0+ iPhone (unchanged). The pure parts run in the macOS package build;
iOS-only files are skipped there, so every stage also builds for the simulator and the device.

**Project Type**: mobile-app (single iOS app + one local Swift package), unchanged

**Performance Goals**: 004 SC-004: usable Home within 1 s and results within 2 s at 30,000 photos
(reference phone, Release). Targets, not measured on a phone. Cost avoided: build 0.67 s and item
load 1.25 s and 569 MB on an M4 Max (004 R5). Cost of saving: a single blob row of 937 KB (20,000
ids) wrote in 2 ms and read and decoded in 5 ms on an M4 Max (research R7); a phone is slower and
unmeasured.

**Constraints**: debounce 500 ms with a 2 s maximum wait; flush at inactive and background;
auto-restore within 24 h and fewer than 2 unfinished restores; remove choices and snapshot expire at
7 days; keep choices at 180 days; scan write failure streak of 3 pauses the scan; "Preparing your
library" after 400 ms; "Checking for changes" after 300 ms; restore counter cleared after 30 s in
the foreground; a group route holds up to 3 anchor photos; snapshot under 3 MB at 30,000 photos
(estimate).

**Scale/Scope**: about 12 new files and 20 touched files across `CleanupKit` and the app, plus
tests, one fixture and one dev-only executable target.

## Constitution Check

| Principle | Gate | Pre-research | Post-design |
|-----------|------|:------------:|:-----------:|
| I. Local-Only Data | New rows hold identifiers, counts, choices, a breadcrumb and a derived copy of data the store already holds; no image or thumbnail is written; same folder, excluded from backup | Pass | Pass (FR-028) |
| II. No Outbound Network | No networking code; CryptoKit and LZFSE are on-device; `check-no-network.sh` unchanged | Pass | Pass |
| III. Offline-Safe Dependencies | No dependency added (system frameworks only) | Pass | Pass |
| IV. User Owns Their Data | Delete All Data covers every new row and the pending writer; "Saved on this iPhone" lists and clears saved results and choices; every removal still needs confirmation (the sheet is never restored, the gate can only remove photos from a selection, never add) | Pass | Pass (FR-025, FR-026). Gap, pre-existing: no export in an open format exists for any iclean data; this feature adds data to it (see Complexity Tracking) |
| V. Verifiable Privacy | No new endpoint, entitlement or networking API; logs carry no photo identifiers; no temporary files | Pass | Pass |
| Data Handling Constraints | Default file protection (readable after first unlock, so background writes work); excluded from backup; no cloud | Pass | Pass |
| Workflow gate | Data & Network statement below | Pass | Pass |

**Result**: PASS, with one pre-existing gap recorded.

### Data & Network statement

- **Data touched**: photo asset identifiers (device-local), the person's ticks, keeper choices and the
  time of each, a navigation breadcrumb (category plus up to three photo identifiers of a group, the
  last photo touched, a counter), a revision counter and format number, and a derived copy of results
  (identifiers, album names, and the metadata `LibraryItemRecord` already stores: kind, dates, size,
  favorite, edit flags, burst id, analysis source, scores, location flag). Not stored: thumbprints,
  feature prints, hashes, thumbnails, image data.
- **Where stored**: the existing SwiftData store in Application Support, excluded from backup, default
  file protection, no CloudKit. Each row can be deleted on its own; Delete All Data removes all of
  them, and "Delete saved data" removes the store, `-wal` and `-shm` together.
- **Network**: none. Nothing here uses a network API.

## Project Structure

### Documentation (this feature)

```text
specs/007-persistent-session/
├── spec.md, plan.md, research.md, data-model.md, quickstart.md, tasks.md
└── checklists/requirements.md
```

### Source Code (repository root)

File names follow the code already being written for this feature where it exists. Everything is
marked planned until its task is done.

```text
Packages/CleanupKit/Sources/CleanupKit/
├── Store/StoreMetaRecord.swift      # NEW: resultsRevision, formatVersion, createdByBuild
├── Store/StateRecord.swift          # NEW: one keyed, checksummed blob row
├── Store/StateCodec.swift           # NEW: LZFSE(JSON) seal/open, SHA-256, StateKey
├── Store/DeferredStore.swift        # NEW: opens and creates the SwiftDataStore off the main thread; open status; erase
├── Store/StoreOpenFailure.swift     # NEW: classify open failures (not yet readable vs damaged vs newer); no quarantine
├── Store/ReviewStateWriter.swift    # NEW: coalescing single writer, debounce, awaited flush, generation
├── Store/Store.swift, SwiftDataStore.swift   # revision rule in the transaction helper, resultInputs, loadLaunchState, state rows, CAS snapshot, setSizes, sizes(for:), deleteAllData
├── Results/ReviewIntent.swift       # NEW: decisions payload + pure applier
├── Results/ReviewSession.swift      # NEW: pure reducer lifted from AppModel (toggle, bulk, keeper, removed, adopt)
├── Results/ReviewPosition.swift     # NEW: Route, ReviewPosition, RouteValidator
├── Results/ResultsSnapshot.swift    # NEW: slim payload, BuilderKey, BuilderVersion, validate
├── Results/ResultsBuilder.swift     # slimmed(), recomputing default selection after removing()
├── Removal/RemovalPlan.swift        # NEW: immutable plan + freshness gate
├── Removal/Remover.swift            # verify before and inside remove
├── Library/PhotoLibrary.swift, PhotoKitLibrary.swift   # stamps(for:), one PHFetchOptions factory, beginObserving()
├── Scanning/VisibleSetValidator.swift   # NEW: pure check of displayed photos against stamps
├── Scanning/SizeMeasurer.swift      # setSizes only (never upsert slim items), never inserts
├── Scanning/ScanPipeline.swift      # 3-failure streak pauses with .storageUnavailable
└── (Package.swift: dev-only executableTarget CrashHarness, macOS)

iclean/App/AppModel.swift, AppEnvironment.swift, icleanApp.swift   # launch phases, publish rules, applier on every apply, scene phase flush, scene-local path
iclean/App/ (background-time helper next to ScanContinuation)      # flush cannot remove photos
iclean/Features/Home, Results, Category, Confirm, Scanning, Settings   # placeholders, Continue row, loading states, RemovalPlan sheet, SavedDataView

Packages/CleanupKit/Tests/CleanupKitTests/     # ResultsRevisionTests, StateRecordTests, StoreCommitTests, ReviewIntentTests, ReviewSessionTests,
                                               # ReviewStateWriterTests, RemovalGateTests, ResultsSnapshotTests, LaunchPlannerTests, ReconcileTests,
                                               # DeferredStoreTests, RouteValidatorTests, FaultInjectionTests, CrashLoopTests, ScanWriteFailureTests,
                                               # Fixtures/shipped-store
icleanUITests/PersistenceTests.swift           # kill-and-relaunch tests
scripts/make-shipped-store-fixture.swift       # writes the current-build fixture in its own process
```

**Structure Decision**: the pure rules (applier, reducer, route validator, snapshot validation,
visible-set check, removal gate) are separate files so they are tested without a store, a library or
a UI. `AppModel` stays the only place that sequences them.

## Design

### Layers

**A. Analysis store (source of truth, unchanged tables)**

- Holds `LibraryItemRecord`, `KeepMarkRecord`, `ScanSessionRecord`, `ScanChunkRecord`.
- Written as today: one transaction per scan chunk, refresh and delete during reconcile, keep marks.
- Not read on the launch path (only a COUNT, the keep marks, and the size columns of the displayed
  photos by id). Read in full by `resultInputs()` only when a rebuild is needed.

**B. Store meta (revision and format stamp)**

- `StoreMetaRecord` singleton, key `meta`: `resultsRevision` (Int64), `formatVersion` (Int, 1),
  `createdByBuild` (String?).
- The counter moves inside the transaction that makes the write, never after it, in these cases:
  a new item, an existing item whose **results projection** changed (every `LibraryItem` field except
  `analyzedAt`, `scanAttempts`, `scanFailure`, `byteSize`, `isSizeEstimated`; album names compared as
  sorted arrays), `deleteItems`, `setKeep`, `clearKeepMarks`, and `setSizes` only for an item that
  goes from no size or an estimate to a measured size (a batch moves it once).
- It does not move for scan bookkeeping (`analyzedAt`, `scanAttempts`, `scanFailure`, chunk and
  session writes), for an identical re-upsert, or for choices and position (those are `StateRecord`
  writes). Why measured sizes count: equal-pixel copies tie on the estimate, so the measured size can
  flip a keeper (research R5).
- Never reset, not even by Delete All Data, so a number is never reused.

**C. Results snapshot (derived, disposable)**

- `StateRecord` key `results`: slim results (the photos that are group members only, with the metadata
  the lists display; no thumbprint, feature print or hash), a header (format version, builder key,
  built at, item count, keep-mark count), `basedOnRevision`, SHA-256 over the stored bytes,
  LZFSE-compressed JSON.
- `builderKey` = `BuilderVersion.current` (a constant a person raises when detectors, thresholds,
  `KeeperRules` or `DateCredibility` change; a golden-output test over the baseline library fails if
  output changes without a bump) + detector set + Pro flags + library access level + time zone and
  calendar identifiers. The key may also carry a string of the threshold constants, so editing one
  invalidates by itself.
- Shown only if: checksum, format version, builder key and `basedOnRevision == store revision` all
  match, header counts equal the store counts (item count, keep-mark count), and it is less than 7
  days old. Otherwise the row is deleted silently and results are rebuilt.
- Written by a compare-and-set: `saveSnapshot(ifRevision:)` writes only if the store revision still
  equals the revision read together with the items. After a rebuild, and again after sizes were
  measured (when that moved the revision).
- Not written on selection changes, and **not patched forward** after a removal or Always keep.

**D. Review intent (decisions)**

- `StateRecord` key `decisions`: `forcedOn {assetID: decidedAt}`, `forcedOff {assetID: decidedAt}`,
  `keeperChoices {assetID: decidedAt}`. Keyed by asset id, never by `ResultGroup.id` (a hash of the
  sorted member ids that changes when one member leaves).
- Event-sourced and normalized after every change, never derived by diffing the selection set:
  `makeKeeper(id)` records a keeper choice and clears `forcedOn[id]` (the choice itself keeps the
  photo unselected, and replaying choices oldest first lets the latest in a group win); an override equal to the current default is pruned; a
  toggle replaces the opposite override.
- Replayed by one pure applier on **every** publish (launch, foreground, scan publish, rebuild, and
  every in-place `removing()` call): (1) keeper choices in `decidedAt` order, (2) default selection
  recomputed from the groups, (3) selection = (defaults + valid `forcedOn`) minus `forcedOff`.
- `forcedOn` is valid only while the photo is still a removable member, not a favorite, not
  keep-marked, not modified after `decidedAt`, and not older than 7 days. `forcedOff` is always
  honored; pruned after 180 days or when the photo is removed. A keeper choice is dropped when the
  photo is gone or not in a group that has a keeper.
- Saved by `ReviewStateWriter` (see Save points). An optional `seenGroups` field is reserved for
  spec 004 and is not written by this feature.

**E. Position (breadcrumb)**

- `StateRecord` key `position`: a typed `Codable` route stack (`category`, `group` identified by up to
  3 member anchor ids), the last photo touched, `savedAt`, and `restoreAttempts`. Never a sheet, the
  photo viewer, the confirm dialog or Settings. Not the type-erased `NavigationPath` (research R9).
- `restoreAttempts` is incremented (awaited, one tiny write) before a restore, and reset by a clean
  flush at `.inactive` or `.background`, or after 30 s in the foreground. Auto-restore is skipped when
  it is 2 or more.
- Validated prefix by prefix against the published results and shortened to the nearest valid
  ancestor: a category must have results; a group is found by any anchor inside that category.
- Auto-navigation within 24 h of `savedAt`; later, or after the counter trips, Home shows
  "Continue reviewing". The live path is scene-local state mirrored into the breadcrumb, so several
  windows (005) stay possible.

### Launch sequence

1. **t = 0 to about 100 ms, main thread, no I/O.** `AppEnvironment.live()` builds a `DeferredStore`
   (no container yet). First frame: Access or Home by the authorization status. `launchPhase =
   .opening`: Home shows the title and redacted rows. No "Scan Library", no "Your library looks
   clean".
2. **Background, user-initiated.** The `DeferredStore` creates the `SwiftDataStore` (container open,
   possible lightweight migration) off the main thread. After 400 ms the placeholder says "Preparing
   your library". A failure is classified (see Failure handling); it is never read as empty.
3. **One read transaction** (`loadLaunchState`): meta, the state rows (checksum verified, a bad row
   deleted), keep marks, the current session, and a COUNT of items. No item row is read.
4. **Off the main thread**: the snapshot gate (checksum, format, builder key, revision, counts, age),
   decode, overlay of the stored sizes onto the restored slim items (a read of the size columns of the
   displayed photos by id), the applier over results, decisions and keep marks, and route validation.
5. **One main-actor publish**: results, selection, keepers, last scan date, interrupted-scan flag,
   `launchPhase = .ready`. If the route is valid, the position is under 24 h old and `restoreAttempts`
   is under 2: await the counter write, then set the path with animations off and scroll to the last
   photo, so the first content frame is the restored screen. Otherwise Home shows the Continue row
   (when a position exists).
6. **Cold path** (no snapshot, or it failed the gate): `launchPhase = .building`, the existing
   "Updating results" row, the saved route applied optimistically, Category and Group screens show a
   loading state (never "Nothing here" or "Group removed" while building). `resultInputs()` returns
   items, keep marks and the revision in one actor turn; build off the main thread; `slimmed()`; the
   first publish always applies; `saveSnapshot(ifRevision:)`; then `SizeMeasurer` (via `setSizes`) and,
   if that moved the revision, one quiet rebuild and a second compare-and-set save.
7. **Reconcile, single-flight, after the first publish.** `beginObserving()` registers the library
   observer without enumerating. (a) Visible-set check: `stamps(for:)` for every displayed member in
   batches of 1,000 (modification date, favorite, existence); missing or changed photos leave results
   and selection through `removing()` and the applier, with one inline note. (b) `quickCheck()` as
   today (skipped while a removal commit is in flight or while an interrupted scan has its own
   catch-up). A "Checking for changes" row shows only if this takes over 300 ms.
8. **Refresh without reshuffling.** If the store revision differs from the revision the shown results
   are based on, rebuild off the main thread from `resultInputs()`. Apply at once when the path is
   empty and no sheet is open; otherwise hold as `pendingResults` and apply when the person is next
   on Home with nothing presented. Every apply goes through the applier, so ticks and keepers carry
   over by photo. An open list only ever loses photos that left the library; it never reorders or
   gains rows under the finger.
9. **Foreground handling.** `onForeground` is ignored until `launchPhase` is `.ready`, and the
   `.active` that fires at launch joins the launch reconcile through the single-flight guard. After
   that a return runs the reconcile and rebuilds only if the revision moved. The unconditional
   `reloadResults()` on every foreground goes away.

### Removal safety (ships with the snapshot)

- When the confirm sheet opens, the writer is flushed and an immutable `RemovalPlan` is built: the
  ids, a subset of results, and per-category totals, after a commit-time freshness gate. The gate
  fetches each id with the same options as the enumeration and drops: photos no longer returned, photos
  that are favorites now, photos whose modification date differs from the stored one, and any group in
  which none of the photos the plan would keep is still in the library (unless the person knowingly
  chose the whole group under 001 FR-016).
- The sheet shows "Checking selection" with Remove off until the gate returns, and counts what it
  dropped. Remove executes exactly the plan; live changes to results or selection do not change an
  open plan, and results are not swapped while a sheet is open.
- `DefaultRemover.remove` checks again inside the call (the library can change between the sheet and
  the tap). Removal still needs the system confirmation and goes to Recently Deleted.
- One `PHFetchOptions` factory serves the enumeration, by-id fetches and stamps, so "gone" means the
  same thing on every path (research R10). Verified on a device with bursts before the gate and the
  visible-set check ship.

### Save points

| Event | Write | Mode |
|---|---|---|
| Toggle, bulk select, keeper change, path change | decisions and/or position | debounced: 500 ms trailing, 2 s maximum wait |
| Scene phase `.inactive` | flush (awaited) | background time requested synchronously in the handler first |
| Scene phase `.background` | flush (awaited) | same, ended when the flush completes |
| Confirm sheet opens | flush (awaited) | then the gate runs |
| Before removal | flush (awaited) | |
| Restore begins | `restoreAttempts` + 1 | awaited, one tiny transaction |
| After a rebuild, after sizes were measured | snapshot | compare-and-set on the revision |

Never `applicationWillTerminate` (not delivered on a jetsam or a force-quit), never `SceneStorage`,
`UserDefaults` or `NSUserActivity` for correctness (research R8 and R9).

**Delete All Data** is safe by a writer generation counter, in this order: bump the generation and
cancel pending writes; clear in-memory choices, path, pending results and any in-flight reconcile;
delete everything including the state rows; keep the revision moving; reject flushes from older
generations. `setSizes` only updates existing rows and never inserts, so a measurement racing the
delete cannot bring a row back.

### Failure handling

- **Open** is off the main thread. Classification: *data not yet readable* (the phone has not been
  unlocked since a restart; for example I/O error 4618) is waited out and retried when protected data
  becomes available; *damaged*, *newer format* and *migration failure* give the volatile state. The
  volatile state runs on an in-memory store, shows "Progress won't be saved this time", leaves the
  files untouched, and offers "Delete saved data" in Settings (also offered after a load failure).
- **Reads**: every `try?` that turns an error into `[]` goes. A failed read is a load failure state.
- **Scan writes**: after 3 consecutive checkpoint, chunk or session write failures the scan pauses with
  `.storageUnavailable` ("Couldn't save progress. Free up space, then tap Resume."), and resumes after
  recovery. Nothing is marked saved that was not.
- **State rows**: a checksum, format or version failure deletes the row silently (snapshot: rebuild;
  decisions: defaults; position: Home).
- **No automatic quarantine** in v1 (research R11).

### Crash points

| Crash at | What survives | What is redone or shown |
|---|---|---|
| Mid scan chunk (003) | every earlier checkpoint, decisions, position; the snapshot row survives but is behind the revision, so it is not shown | at most the unfinished chunk (32 photos); results are rebuilt; Resume Scan row |
| Mid snapshot write | one atomic transaction: the old row or the new row, never a mix | an old row behind the revision fails the gate; one rebuild |
| Mid rebuild, before the snapshot write | everything; a build persists nothing | the rebuild at next launch |
| Mid decisions write, or inside the debounce window | the last committed decisions; every change older than the window (a committed save survives SIGKILL, jetsam and a force-quit) | changes in the open window (at most 500 ms, 2 s maximum) are lost and the person re-ticks |
| Confirm sheet open, before the plan is built | nothing was removed; decisions were flushed when the sheet opened | nothing; the sheet is never restored |
| During the system delete dialog, or after Photos deleted but before the store commit | the decisions; Photos may or may not have deleted the photos (undocumented) | at launch the visible-set check drops absent photos; present ones stay ticked and need a new confirmation; the quick check removes the rows; nothing is retried |
| Mid removal commit (delete items, revision bump) | all or nothing | if nothing committed, the previous state; the quick check cleans up |
| During migration (first launch adds two tables) | the old store (40 SIGKILLs at random 20 to 350 ms offsets during open, all reopened intact, probe on a Mac) | the migration restarts off the main thread; the new tables start empty and the cold path rebuilds |
| While restoring a route | decisions, snapshot; the counter was written first | next launch tries once more, then skips auto-restore and shows the Continue row |
| With the sheet, viewer or Settings open | the last saved category or group, and the flushed selection | the person lands on the category or group screen |
| Mid reconcile | every plan write is idempotent | the diff is recomputed |
| Power loss or kernel panic within seconds of a commit | a consistent earlier state of all layers together (one file, WAL with synchronous NORMAL: durable against process death, not against power loss) | the last seconds of choices; a photo deleted in Photos but not yet recorded is caught by the visible-set check and the gate |
| Store file corrupt (header, truncation, interior page) | the Photos library; the damaged files are left as they are | open throws (or a later read throws): volatile notice or load failure, never "looks clean"; "Delete saved data" is the person's choice |
| State row damaged, newer, or built under another builder key | the store and everything else | snapshot: silent rebuild; decisions: defaults; a new builder key keeps decisions (asset-id keys) |
| Older build opens a newer store | items, sessions, chunks, keep marks | the older schema drops the two new tables silently, so saved results and choices rebuild or reset (accepted, testing builds only) |
| Delete All Data with a write pending, then background | nothing: generation counter refuses the write | after a relaunch no state row exists |
| Kill during size measurement | measured sizes already in the store | restored results get sizes overlaid; measuring continues from there |

## Delivery stages

Each stage ends with `swift test`, an `xcodebuild` for the simulator **and** the iPhone (the macOS
package build skips iOS-only files), `xcodegen generate` after new files, and lint of the files
touched. Stages 1, 4 and 5 must keep their order: no new blocking store call before stage 1, and
removal safety (stage 4) before any snapshot (stage 5).

| Stage | Ships | Gate |
|---|---|---|
| S0 | fixtures (`shipped-store`), superseded notes in `docs/`, device baselines and probes | `StoreMigrationTests` opens both fixtures unchanged; signposts for container open recorded on a copy of the real store; burst and hidden by-id probe on the phone |
| S1 | `DeferredStore` creates the `SwiftDataStore` off the main thread; main-thread assertion hook; `StoreMetaRecord`, `StateRecord`, `StateCodec`; revision rule, `resultInputs`, `loadLaunchState`, state rows, CAS snapshot, `setSizes`; kill harness | `ResultsRevisionTests` table; `StateRecordTests`; `StoreCommitTests`; `CrashLoopTests` (100 runs); the UI suite runs with the hook and never calls the store on main |
| S2 | open failure visible, load failure instead of empty, scan write-failure pause, "Delete saved data" | `FaultInjectionTests`; `ScanWriteFailureTests`; UI test for the volatile notice |
| S3 | review choices persist (applier, reducer, writer, scene flush, Delete All Data order); foreground no longer resets | `ReviewIntentTests`, `ReviewSessionTests`, `ReviewStateWriterTests`, Delete All Data test; UI: selection, keeper and foreground reload |
| S4 | removal safety: stamps, one fetch-options factory, `RemovalPlan`, "Checking selection" | `RemovalGateTests`; UI: kill inside the sheet, kill during removal |
| S5 | results snapshot: slim shape, `BuilderKey`, golden test, CAS save, restore, pending results, no patch-forward, size overlay | `ResultsSnapshotTests`; golden test; `SizeMeasurerTests` (blobs survive); UI relaunch without rescan; Release benchmark |
| S6 | launch path: launch phases and placeholders, single-flight reconcile, visible-set check, foreground guard | `LaunchPlannerTests`; `ReconcileTests`; cold-start UI tests; device signposts to first content frame |
| S7 | saved place: routes, restore, counter, Continue row, loading states, scene-local path | `RouteValidatorTests`; UI: category, dissolved group, crash during restore, kill in sheet |
| S8 | "Saved on this iPhone" screen, Clear saved results, Reset review choices | inventory tests; Delete All leaves zero state rows; accessibility audit |
| S9 | on-device soak (kill mid-scan, mid-selection, viewer open, during removal; restart; Limited access) | recorded in `validation-log.md` |

The optional change-token delta for the quick check is **not** a stage. It is built only if the
foreground reconcile costs more than about 1.5 s or 300 MB at 30,000 photos on the phone (research
R13).

## Risks & open items

- **A stale snapshot judged valid.** The revision tracks store inputs only. One transaction helper
  decides the bump, a table test covers every mutating method, header counts are a backstop, the age
  limit is 7 days, the visible-set check validates every displayed photo against Photos, and the gate
  runs at commit time. Residual: the view is only as current as the last reconcile.
- **Rules change without a bump.** The builder key relies on a constant a person raises. The golden
  test covers only the baseline library, so a keeper or date change that does not alter the baseline
  output could show old results for up to 7 days. Not adopted: stamping the key with an app build
  number (`CFBundleVersion` is the constant 1 today; making it a commit count in `project.yml` would
  invalidate on every update and every development install). Folding the threshold constants into the
  key reduces the gap. Owner's call.
- **The size overlay may read more than the size columns.** A property-limited SwiftData fetch did not
  lower memory in a probe (research R14), so reading the sizes of the displayed photos may fault their
  blob columns (about 5 KB each; 10 to 20 MB for 2,000 to 4,000 members, estimate). Measure it; if it is
  too heavy, run the overlay after the first publish (it changes sizes on screen, not keepers).
- **Slim items written back to the store.** `results.items` has no blobs, and `upsert` rewrites every
  column. `SizeMeasurer` must use `setSizes`, with a test that blobs survive. Any future code that
  upserts from results is rejected in review.
- **The quick check still reads every stored photo.** About 570 MB at 30,000 photos on a Mac, and
  about 1.9 GB at 100,000 if it scales linearly (estimate). This feature moves it off the first frame
  and off the main thread but does not lower its peak; a jetsam during it counts as an unfinished
  restore (cleared after 30 s). Fix: a slim planner input (004 FR-025, keyset paging measured at 37 MB,
  research R14), or the token delta (R13).
- **Migration time on the phone is unmeasured.** Two Mac measurements disagree (about 2.0 s for a
  column migration and 0.08 to 0.18 s for adding only two tables to a 143 MB store). Off-main plus
  "Preparing your library" make it a one-time wait.
- **Restoring a position can crash or strand.** Typed routes, validation, loading states and the
  counter bound it. The first-frame behavior (no Home flash, no push animation) is unverified on a
  device.
- **Going back by ourselves after a force-quit departs from Apple's behavior** (Apple drops preserved
  UI state then, as a safety precaution). The window is one constant; 0 gives the row only.
- **Burst and hidden photos.** The SDK header says `includeAllBurstAssets` defaults to NO and that a
  by-id fetch includes hidden assets by default; a simulator probe returned hidden photos from neither.
  If by-id fetches omit non-key burst frames, the gate and the visible-set check would wrongly drop
  them. One options factory plus a device check before they ship.
- **Spec 004 interplay.** 004 plans block-boundary publishes; they must go through the applier and the
  same compare-and-set save. 004's data model is amended (note dated 2026-10-18).
- **Snapshot size and decode time at 100,000 photos** are estimates (target under 3 MB at 30,000).
  Fall back to interning more fields, or per-category rows, if measured too large.
- **Power-loss durability is tolerated, not fought.** Saves survive process death; a power cut returns
  all layers together to an earlier commit.
- **Export in an open format** (constitution IV) does not exist for any iclean data. Not built here.
- **A failed save of choices is not announced in v1.** The choices stay on screen and the save is
  retried at the next save point.

**Open questions**: what happens to an in-flight system delete if the process dies while the dialog is
up (undocumented; Photos is treated as the truth either way); how a Limited selection change appears to
the library (only matters for the deferred token); whether the modification date changes for every edit
that should invalidate a stored "remove" (it changed for favorite and content edits in a simulator
probe, not for album membership, so the favorite flag is compared too); whether `-wal` and `-shm` inherit
the default protection class (read `protectionKey` on a device); the real cost of the launch-time quick
check on the phone.

**Pitfalls to remember**: copy, move or delete the store as a trio (`.store`, `-wal`, `-shm`), because
dropping the `-wal` loses recent commits with no error; never key anything saved by a group id; never
persist or restore presentation state; keep `Route` (pushes) and sheet state as separate types; never
set a stricter file protection on anything the scan touches while locked; do not move the store into an
App Group container (a suspended app holding the lock can be killed); a `XCUIApplication.terminate()`
is a real SIGKILL only without a debugger attached (run through `xcodebuild`); the simulator shares the
host kernel and shows neither data protection nor power loss; Debug builds are about 142 times slower,
so launch numbers come from Release.

## Complexity Tracking

| Choice | Why it is needed | Simpler option rejected |
|---|---|---|
| Five layers (store, meta, snapshot, decisions, position) | each has a different owner, lifetime and failure rule: the snapshot is disposable, the choices are not | one blob for everything: a bad snapshot would take the person's choices with it |
| One generic `StateRecord` keyed blob, not typed tables | the store is unversioned and each schema change costs launch time; new kinds become new keys | one table per kind: more migrations |
| Event-sourced overrides with `decidedAt` | lets the applier order keeper choices and toggles and expire them; avoids phantom decisions from diffing | saving the whole selection set: loses meaning when defaults or groups change |
| Revision counter plus checksum plus counts | a counter alone misses a forgotten bump; counts and checksums catch what it misses | timestamps (can move backwards, miss deletes) |
| `DeferredStore` actor | the store must be created off the main thread (probed), and the open must be able to fail visibly | opening in `App.init`: blocks the first frame and hides failures |
| Writer actor with a generation counter | makes Delete All Data and ordering of writes safe | writes from `AppModel`: a pending write can resurrect deleted data |
| No export (constitution IV) | out of scope for this ask | none: recorded as a gap and a follow-up |

No constitution violations to justify.
