# Feature Specification: Vision Work Only Where a Detector Reads It

**Feature Branch**: `010-defer-vision-work`

**Created**: 2026-10-21

**Status**: Implemented (planner, chunks, store, analyzer, tests, Mac measurements); phone numbers not taken

**Input**: User description: "The scan should not run the Vision feature print or face quality for a photo
that no detector can use them for, while the results stay identical to today's."

**Builds on**: [009-parallel-scan](../009-parallel-scan/spec.md) (Decision 6 named this the largest lever
left: the Neural Engine ends a Mac scan and Vision's two passes are what it serves),
[008-staged-cleanup-at-scale](../008-staged-cleanup-at-scale/spec.md) (Decision 2 described it and left it
for "a signal mask on stored items and a repair rule"), [003-durable-chunked-scan](../003-durable-chunked-scan/spec.md)
(chunks, and FR-004: resuming does not enumerate the library) and
[007-persistent-session](../007-persistent-session/spec.md) (the store's revision).

## Why (measured in 009, 2026-10-21, M4 Max)

The feature print (`FeaturePrint.compute`, 436 photos a second) and face quality (`FaceQuality.score`, 490 a
second) are served by the Neural Engine, which caps the whole analyzer at 328 photos a second however many
cores wait for it: 77 s for the 25,500 photos of the 30,000-item demo library. `ScaleBench --real-scan --demo
--count 30000 --latency-ms 15 --profile mac --what-if-defer-vision` (a what-if that knew the whole library)
took 61 s instead of 81 s. The demo library is burst-heavy: two thirds of its photos have a neighbour. A
real library has about a third of its photos in bursts (004 research), so about two thirds of the Vision
time would go.

## Who reads what (checked in the code, not remembered)

| Stored field | Read by | For which photos |
|--------------|---------|------------------|
| `Analysis.featurePrint` | `SimilarShotsDetector.isSameMoment`, through `FeaturePrintCache` and the parallel decode | A pair of photos at most `SimilarThresholds.window` (60 s) apart that are not frames of one burst. Nothing else decodes a print |
| `Analysis.faceQuality` | `KeeperRules.similarOrder`, through `similarKeepers`, which `SimilarShotsDetector` and `CleanupResults.removing` call | Members of a similar-shots group, and a group joins photos by a pair within 60 s or by a shared `burstID` (however far apart) |
| `dHash`, `thumbprint`, `sharpness`, `aestheticsScore` | duplicates, blur, similar shots | Every photo. Unchanged by this spec |

`SimilarShotsDetector` receives only photos and live photos with an analysis, and any earlier category can take
photos away from it, never add one. So a photo's print is read only if another **photo or live photo with a
capture date** is within 60 s of it, and its face quality only if that is so or it has a `burstID`. Videos
(Pro) and screenshots never reach `SimilarShotsDetector`. Call this the photo's **Vision demand**:

- `featurePrint` is demanded when another photo/live photo of the library lies within 60 s (`timeIntervalSince <= window`, as the detector tests it; a photo without a capture date has none);
- `faceQuality` is demanded in that case, or when the photo has a `burstID`;
- neither is demanded for a video or a screenshot.

The demand is computed from the **library** (every photo's metadata), a superset of the photos that will be
analyzed: a neighbour whose own analysis fails or that an earlier category takes away still counts. A
superset only does more Vision work than necessary; it never does less than a detector reads.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The scan skips Vision for photos nothing can group (Priority: P1)

A person with 30,000 photos taps Scan. The photos taken alone (no other photo within a minute, no burst) are
hashed, measured and stored as before, but the Neural Engine is not asked for their feature print or face
quality. The scan ends when it has served the rest.

**Independent Test**: `ScaleBench --real-scan --demo --count 30000 --latency-ms 15 --profile mac` (defers by
default; `--no-defer-vision` runs every photo's Vision work, as 009 did).

**Acceptance Scenarios**:

1. **Given** a photo with no neighbour within 60 s and no `burstID`, **When** it is scanned, **Then** the
   analyzer is asked for neither request, and the stored item says so.
2. **Given** a photo with a neighbour within 60 s, **When** it is scanned, **Then** it gets both, as today.
3. **Given** a photo with a `burstID` and no neighbour within 60 s, **When** it is scanned, **Then** it gets
   face quality and no feature print.
4. **Given** the 30,000-item demo library at 15 ms a preview on the Mac profile, **Then** the scan takes about
   as long as the what-if said (a quarter less: 65–68 s against 86–92 s measured), 9,200 of its 27,690 analyzed
   photos get neither request, and the results digest is `fa169c4d97929604`.

### User Story 2 - What the scan finds does not change (Priority: P1)

**Independent Test**: `DeferredVisionTests` (a library scanned in two stages equals a one-shot scan of all of
it, on both profiles) and the digests in the validation log.

**Acceptance Scenarios**:

1. **Given** a library, **When** it is scanned once with every photo's Vision work and once with the work
   deferred, **Then** `CleanupResults` are **equal** (`==`): categories, groups, members and their order,
   keepers, date notes, default selection, not-scanned count and the listed items.
2. **Given** a library scanned and then a batch of photos added, some within 60 s of photos that were stored
   without a print, **When** the second scan ends, **Then** the stored photos that now have a neighbour were
   analyzed again, no other stored photo was, and the results equal a one-shot scan of the whole library.
3. **Given** a stored photo that gets a `burstID`, or whose capture date (or a neighbour's) changes without its
   modification date changing, **When** the next scan or quick check runs, **Then** the same rule applies.
4. **Given** a feature print that is `Data()` because the Vision request failed (as before), **Then** it is
   not treated as skipped and is not retried, exactly as before.

### User Story 3 - A quick check keeps the store consistent (Priority: P1)

**Acceptance Scenarios**:

1. **Given** new photos within 60 s of stored photos that have no print, **When** a quick check runs, **Then**
   it analyzes the new photos and those stored photos (it is the same plan as a full scan's) and the store
   holds what a one-shot scan of the library would hold, for everything a detector reads.

### User Story 4 - Phones and old stores are safe (Priority: P1)

**Acceptance Scenarios**:

1. **Given** the phone profile (4 wide, one lane), **Then** the same rules and the same results as the Mac
   profile; only the width differs. The test runs both.
2. **Given** a store written by an earlier build (no skip record on any item or chunk), **Then** it opens
   unchanged, every item reads as "nothing skipped", and nothing is analyzed again because of this spec.
3. **Given** a job planned by an earlier build and resumed by this one, **Then** its chunks carry no skip
   masks and every photo gets both requests, as it was planned.
4. **Given** a scan paused, killed or resumed in a new process, **Then** the photos still to do keep the
   decisions made when the job was planned, without enumerating the library (003 FR-004).

## Requirements *(mandatory)*

- **FR-001**: `VisionWork` MUST be an option set of `featurePrint` and `faceQuality`. `Analyzer` MUST gain
  `analyze(_:metadata:vision:)` with a default that calls the existing method, so analyzers that ignore the
  request (every fake) compute everything and keep working. `DefaultAnalyzer.analyze(_:metadata:)` MUST be
  `analyze(vision: .all)`.
- **FR-002**: `Analysis.skippedVision` MUST record the Vision work an analyzer did not do on purpose. It MUST be
  empty for every analysis made without a request, and for a request that failed (an empty print then still
  means "Vision unavailable").
- **FR-003**: `LibraryItemRecord` MUST store it in an optional column (`nil` for items written before), read
  it in `item`, `itemWithoutFeaturePrint` and `summary`, and `StoredItemSummary` MUST carry it, so a plan reads
  it without any fingerprint.
- **FR-004**: `VisionDemand` MUST implement the rule above over a library's metadata: one sort of the photos'
  dates, then two binary searches a photo. `ScanPlanner.plan` MUST return, for every item to analyze, the work
  to skip.
- **FR-005**: `ScanChunk` MUST carry that decision: `skipPrintMask` and `skipFaceMask`, a bit per asset, stored
  in optional columns of `ScanChunkRecord` (`nil` reads as 0, "skip nothing"). `ScanPlanner.chunks` MUST set
  them from the plan, and `ScanPipeline` MUST ask the analyzer for exactly the rest, in every path (parallel
  chunks, lanes, a chunk that runs alone after a crash).
- **FR-006 (repair)**: A stored, analyzed photo MUST be planned for analysis again when the Vision work it
  skipped is demanded by the library as it is now. The plan MUST list these photos (`ScanPlan.repairs`), they
  MUST be analyzed in chunks like any other item, in a full scan, in a quick check and in the catch-up of a
  resumed job, and a photo MUST NOT be repaired when what it skipped is still not demanded.
- **FR-007**: The repair MUST NOT be skipped because the photo's metadata did not change. The decision uses
  the library's metadata at plan time and the stored skip record, nothing else (not the modification date).
- **FR-008**: `SimilarShotsDetector` MUST NOT call two photos the same moment on the thumbprint alone when
  either one's feature print was skipped (the pair is left ungrouped until the repair has run). With no print
  skipped anywhere, nothing changes. Burst frames still group by `burstID`.
- **FR-009**: `DefaultResultsBuilder` MUST keep face quality in `CleanupResults.items` only for the members of
  similar-shots groups and drop the skip record from every listed item, so results of a deferred scan and of a
  complete one are equal values. Face quality of the other listed items is read by no one.
- **FR-010**: `ScanPipeline(deferVision:)` MUST default to true; false plans no skip and no repair (the 009
  behaviour), for measurement and for tests.
- **FR-011**: Nothing may change what counts as a duplicate, a similar shot, a blurry photo, a screenshot or
  a keeper. `Features`, `Shared` and `icleanApp.swift` are not touched.

## Decisions (the four design questions)

1. **How a stored item says its Vision work was skipped.** `Analysis.skippedVision`, an option set stored as an
   optional integer on `LibraryItemRecord` (`visionSkippedRaw`). It is a flag **beside** the data, not a value
   of it: a skipped item has `featurePrint == Data()` and a flag; an item whose request failed has
   `featurePrint == Data()` and no flag. Only the first is ever repaired. Adding an optional column is a
   lightweight SwiftData migration, as 003 and 006 did; `StoreMigrationTests` opens the stored fixture of the
   build before the durable scan and finds it unchanged. The analyzer sets the flag from what it was asked and
   did not do, so an analyzer that ignores the request is never wrongly flagged. The format version stays 1, as it did for the
   columns of 003 and 006. The cost of going back to an earlier build with a store this build wrote is that
   build reads a skipped print as "Vision unavailable" and groups on thumbprints alone for the photos that were
   still waiting for a repair; this build never produces that state in its own results (FR-008).
2. **Where the decision is made and kept: the plan, in the chunk.** The demand needs the whole library's dates,
   which a chunk of 32 photos does not have, and a resume must not enumerate the library (003 FR-004; a test
   pins `fetchAllItems` at zero calls before the first preview). So the planner decides when it plans, and the
   decision rides with the work in `ScanChunk` (two masks, as the done mask is one). A resumed or reclaimed job
   analyzes the remaining photos exactly as planned. If the library changed in between, the catch-up at the
   job's end plans again (FR-006) and repairs whatever the change made wrong.
3. **The repair rule.** For each stored photo with a skip record, `VisionDemand` of the **current** library is
   asked what the photo demands now; if it intersects what was skipped, the photo joins `toAnalyze`. This one
   rule covers a photo arriving later within 60 s, a capture date edited without a new modification date (the
   metadata is refreshed, not re-analyzed, by `ScanPlanner` today), a `burstID` assigned later, and a
   neighbour changing kind or date. A repaired photo is analyzed again whole, like a changed one: its
   `dHash`, thumbprint, sharpness and aesthetics come out equal, and if its preview is unavailable then it
   is stored as not scanned like any photo whose preview is gone. Repairs count in the job's total.
   Photos that **lose** a neighbour keep the print they have (nothing reads it; the next full re-analysis, if
   one ever happens, drops it).
4. **What a quick check does.** The plan is the same function, so a quick check repairs. It analyzes new
   and changed photos only (001 FR-005a, unchanged) and, with them, the stored photos those arrivals made
   demanding, which are at most the photos within a minute of a new one.
5. **The phone.** Nothing profile-specific: decisions are made by the planner and carried by chunks, so
   `.phone` and `.mac` produce the same stored values. The phone gains the most in proportion, because it
   has the same Neural Engine work per photo and less other capacity. Not measured on a phone.
6. **Videos (Pro).** No detector reads a video's feature print (`DuplicateVideoDetector` uses hash,
   miniature and duration), so a video in a Pro scan skips it too. The free app does not analyze videos.
7. **Not done.** A photo whose only neighbours are frames of its own burst could skip its print too (pairs of
   one burst are not compared); bursts are rare and the rule would then depend on a second relation, so the
   photo keeps its print. The repair re-analyzes a photo whole although its hash, miniature and sharpness come
   out equal; repairs are few (the photos within a minute of new ones), so only the Vision requests are saved.

## Success Criteria

| | Before (complete Vision work) | After (deferred) | How measured |
|---|---|---|---|
| Scan of the `large30k` demo library, Mac profile, 15 ms a preview | 86.0 s, 91.8 s | 68.2 s, 65.0 s (−21% to −29%) | `ScaleBench --real-scan --demo [--no-defer-vision]`, runs interleaved on a noisy machine |
| Same, bench library, 30,000 / 3,000 items | 86.7 s / 8.9 s | 68.7 s / 6.8 s | same, without `--demo` |
| Photos given neither request (demo library) | 0 | 9,200 of 27,690 analyzed | `vision:` line of the bench |
| Results digest, stored-analysis digest | `fa169c4d97929604`, `b99703de218f60a6` | identical (and `30b0ab850af1d956`, `bf7161cea2f5ee27` for the bench library) | same |
| Two-stage scan against a one-shot scan | | equal `CleanupResults` (slimmed), exactly the new and the made-demanding photos analyzed | `DeferredVisionTests` |
| CPU time of the phone profile's 30,000-item scan | 166.7 s | 138.1 s (−17%); wall time 223.1 s → 203.7 s, because that scan is bound by preview latency on this Mac, not by the Neural Engine | `--profile phone` |
| Peak footprint | 232–234 MB (scan) | unchanged | `phys_footprint` |

Details, including the machine's noise and what was not measured (a phone), are in [validation-log.md](validation-log.md).

## Validation

See [validation-log.md](validation-log.md).
