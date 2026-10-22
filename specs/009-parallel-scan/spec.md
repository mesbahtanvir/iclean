# Feature Specification: A Scan That Uses the Whole Mac

**Feature Branch**: `009-parallel-scan`

**Created**: 2026-10-21

**Status**: Implemented (scan, results build, Mac profile, tests, Mac measurements); phone numbers not taken

**Input**: User description: "Make the library scan much faster on the Mac by using every CPU core, the
GPU and the Neural Engine, without changing what the scan finds. The iPhone keeps its conservative limits."

**Builds on**: [003-durable-chunked-scan](../003-durable-chunked-scan/spec.md) (chunks, leases, checkpoints
are unchanged in meaning), [008-staged-cleanup-at-scale](../008-staged-cleanup-at-scale/spec.md) (whose
Decision 3 kept the width at 4 for want of a run profile; this adds one) and
[005-all-apple-platforms](../005-all-apple-platforms/spec.md) (the Mac app).

## What was measured (2026-10-21, M4 Max, 14 cores, 36 GB)

Everything below ran in release builds with the real `DefaultAnalyzer`, never a fake one (`ScaleBench
--real-scan`, `--analyzer-scaling`, `--vision-probe`; numbers in [validation-log.md](validation-log.md)).
The 30,000-item library is the app's own `-DemoScenario large30k`, reproduced by `--demo` (it gives the
same 772 duplicate groups, 4,441 similar, 1,232 blurry, 1,386 screenshots and 50 videos as the app).

| # | Finding | Measured |
|---|---------|----------|
| 1 | **The Neural Engine is the ceiling, not the cores.** Vision's feature print and face-quality requests are served at about 436 and 490 photos a second however many threads ask (two threads reach it). The whole analyzer reaches 328 photos a second at a width of 4 and stays there at 8, 14 and 28 | analyzer alone: 96/s at width 1, 189 at 2, 320 at 4, 328 at 8, 329 at 14 |
| 2 | **The CPU math is not the limit.** dHash, miniature and sharpness together cost 3.6 ms a photo, scale 8× over 14 cores (2,240 photos a second) and use 2.4 cores while the scan runs | `--analyzer-scaling` |
| 3 | **Vision already runs on the Neural Engine.** Pinning a request to the ANE gives the framework's own answer to the bit. The GPU gives 131 photos a second, 3.3× slower, and a different feature print (largest element difference 8.1e-3); the CPU 35 a second. Putting some photos on the GPU would add at most 30% and would make a photo's stored print depend on which device was free | `--vision-probe` |
| 4 | **Batching requests does not help.** Both Vision requests on one handler: 215 photos a second at width 4, against 328 for one handler each. Two processes together reach 562 a second against 435 for one: part of the cap is per process, which an app cannot use | `--vision-probe` |
| 5 | **The app's scan was bound by its width and its chunk boundaries.** At the app's setting (4 photos at a time, one chunk at a time) and 15 ms a preview, 3,000 photos took 23–24 s (130 a second) and 30,000 took 218–230 s, the 3 min 51 s seen in the app. A width of 14 with the same loop reached only 185 a second at 30,000, because every chunk waits for its slowest photo, then for the store, before the next starts | `--real-scan` |
| 6 | The results build of the 30,000-photo look-alike library was 7.1 s: 2.7 s reading the store (one thread), 3.7 s confirming duplicate pairs (one thread, 274 million bucket pairs), 0.6 s comparing similar shots | `--results-profile` |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The scan finishes in a third of the time on a Mac (Priority: P1)

A person with 30,000 photos taps Scan on the Mac. Every core is busy with the previews and the math, the
Neural Engine is never idle, and the scan ends when the Neural Engine has served the last photo, not
when the slowest of a handful of photos in a chunk comes back.

**Independent Test**: `ScaleBench --real-scan --demo --count 30000 --latency-ms 15 --profile mac`.

**Acceptance Scenarios**:

1. **Given** the 30,000-item demo library at 15 ms a preview, **When** the Mac profile scans it, **Then**
   it takes under a third of the old time (218 s before) and within 10% of the Neural Engine's own
   limit for the photos in it.
2. **Given** the same library, **When** the scan ends, **Then** the stored analysis, the categories,
   groups, keepers and default selection equal the old scan's (same digests).

### User Story 2 - Nothing the scan finds changes (Priority: P1)

**Independent Test**: `ParallelScanTests.aWideScanFindsExactlyWhatANarrowScanFinds` and the digests in the
validation log.

**Acceptance Scenarios**:

1. **Given** one library, **When** it is scanned once one photo at a time and once wide (8 photos, 4 lanes,
   write-behind), **Then** every photo's stored dHash, miniature, sharpness, aesthetics score and face quality are
   equal, feature prints are at distance 0, the session counters are equal, and results built serially and in
   parallel from either store are equal (categories, groups, members, keepers, selection, not-scanned count).
2. **Given** a store of 3,450 items, **When** it is read by one thread and by eight, **Then** the summaries,
   the items without prints and the prints are equal.
3. **Given** 3,000 look-alike photos or 2,400 photos in runs a few seconds apart, **When** duplicates and similar
   shots are found serially and in parallel, **Then** the groups are equal.

### User Story 3 - The iPhone keeps its limits (Priority: P1)

**Independent Test**: `ParallelScanTests.theMacProfileIsWideAndThePhoneProfileIsTheOneSpec008Validated`; the
iOS simulator UI suite.

**Acceptance Scenarios**:

1. **Given** an iPhone, iPad or Vision Pro, **When** the app scans, **Then** it uses `ScanProfile.phone`: 4 photos
   at a time, one chunk, every chunk written before the next, no adaptation, serial store reads and serial
   pair comparisons. The code that runs is the code spec 008 validated.
2. **Given** a Mac, **When** the system is warm or in Low Power Mode, **Then** the width falls (a quarter off at
   `.fair`, half in Low Power Mode, never below 2); at `.serious` the scan pauses as before.

### User Story 4 - The results build is faster too (Priority: P2)

**Acceptance Scenarios**:

1. **Given** the 30,000-item look-alike store, **When** results are built on the Mac, **Then** the read and the
   build together take under half the old 7.1 s with the same result digest.

## Requirements *(mandatory)*

- **FR-001**: `ScanProfile` MUST hold the settings of a scan: photos in flight, lanes, chunk size, write-behind,
  whether it adapts to heat and Low Power Mode, and threads for building results. `.phone` MUST be the
  4-wide, one-lane, no-write-behind, serial profile; `.mac()` MUST scale with `activeProcessorCount`;
  `.current` MUST be `.mac()` on macOS and `.phone` elsewhere.
- **FR-002**: The pipeline MUST work on up to `lanes` chunks at once. A lane leases a chunk (003 FR-002, the
  lease is written before any work), opens its previews, analyzes them with the profile's width shared out
  over the lanes, and hands the result to the writer. A chunk MUST NOT be leased again before its last
  write has landed.
- **FR-003**: One writer stage MUST store finished chunks in order, up to 8 in one transaction when it is
  behind. The session a write carries MUST be the stored session plus the counters of exactly the chunks in
  that write, so counters never run ahead of the saved results (002 G1) and a failed write's counters
  travel with its results to the next write. Lanes MUST NOT start a chunk while more than `writeBehind`
  chunks wait.
- **FR-004**: A pause MUST be acknowledged only when every lane has stopped and the writer is idle, and MUST
  release every chunk this process leased, in a write that cannot be overtaken by a chunk's own write.
- **FR-005**: A chunk that must run alone (after a crash, 003 FR-006) MUST run with no other chunk in flight,
  so a death is still blamed on one photo. One death MUST count once against the crash budget however many
  chunks were running.
- **FR-006**: Results MUST be identical for every profile: the analysis of a photo does not depend on the width,
  and the grouping of photos does not depend on the number of threads.
- **FR-007**: `DuplicatePhotoDetector`, `DuplicateVideoDetector` and `SimilarShotsDetector` MUST take a
  `parallelism`. One MUST run the serial code unchanged. More MUST confirm candidate pairs in slabs of rows,
  join what each thread confirms in its own union-find and join those in a fresh one; high-pass images MUST be
  computed once for all threads and bounded at 16,384.
- **FR-008**: `SwiftDataStore` MUST read items in slices on up to 6 threads with a context each, joined in slice
  order, only inside one actor turn (nothing is written between slices). One thread MUST read as before.
- **FR-009**: `StandardPipeline.detectors` MUST default its parallelism to the platform's profile, so the
  app gets it without changes beyond `AppEnvironment`'s choice of the profile.
- **FR-010**: Vision requests MUST keep the framework's choice of device (the Neural Engine where there is one).
  Their outputs MUST NOT depend on which photos run at the same time.

## Decisions

1. **The Neural Engine is the ceiling; the GPU is not used for Vision.** Measured in findings 1, 3 and 4. A
   GPU or CPU feature print differs from the Neural Engine's in the third decimal; splitting photos over devices
   would make results depend on scheduling, which FR-006 forbids, for at most 30% more throughput. The width
   is what hides preview latency, the store and the chunk end behind the Neural Engine, and 14 does.
2. **No Accelerate, Metal or Core Image for the per-photo math.** It costs 3.6 ms of the 10 ms a photo and
   already runs 8× over the cores; the Neural Engine, not the math, ends the scan, so a faster miniature would
   not shorten it. `vImage`/Core Image resampling would also change the stored miniatures and hashes, which
   the groups are made from. Revisit if Vision work is deferred (Decision 6), after which the math is next.
3. **Lanes, not one sliding window.** A lane is today's `runChunk` with its own width, so leases, retries,
   isolation, give-up and the checkpoint transaction mean what they meant. What changed is state shared
   between lanes: counters (a tally per chunk, applied by the writer), the leased chunks (a set), the
   unsaved results, and the pause acknowledgement. A sliding window over photos would have rewritten those
   meanings.
4. **Write-behind of 24 chunks on the Mac, 0 on a phone.** A results rebuild reads the store for a second
   or more; the writer waits behind it and the lanes keep going for up to 24 chunks (about 5 seconds of
   scan, 6 MB). On a phone the next chunk waits for the last one's write, as before.
5. **The results build is parallel only where the profile says so.** Phone: one thread, the code of spec 008.
6. **Vision work is still done for every photo.** 008 Decision 2 stands: feature print and face quality could be
   skipped for photos with no neighbour within 60 seconds. Measured here as a what-if (`--what-if-defer-vision`):
   the demo library, whose bursts make two thirds of its photos neighbours, scans in 61 s instead of 83 s; a real
   library with about a third of its photos in bursts would save about two thirds of the Vision time. It needs
   a mask on stored items and a repair rule for neighbours that arrive later; it is the largest remaining
   lever and is left for its own entry.

## Success Criteria

| | Before | After (Mac profile) | How measured |
|---|--------|---------------------|--------------|
| Scan of the `large30k` demo library, 15 ms a preview | 217.5 s (the app's 3 min 51 s) | 80.7 s, within 5% of the Neural Engine's own limit (77–78 s) | `ScaleBench --real-scan --demo` |
| Same, 3,000 items | 23.4 s | 8.2 s | same |
| Scan of the bench's 512 × 384 library, 30,000 / 3,000 items | 229.9 s / 24.3 s | 80.7 s / 8.2 s | `ScaleBench --real-scan` |
| Results build, 30,000 items (read + build) | 6.6–7.2 s (demo store), 4.0–4.4 s (bench store) | 1.6–1.7 s, 1.3–1.4 s | `ScaleBench --results-profile` |
| Result digests, stored-analysis digests | | identical in all four libraries and sizes | `ScaleBench`, `ParallelScanTests` |
| Phone profile at 3,000 / 30,000 items on the same Mac | 23.4 s / 217.5 s | 23.4–23.7 s / 227.8 s | `--profile phone` |
| Peak footprint of a 30,000-item scan / of its results build | 227–237 MB / 322–354 MB | 241–253 MB / 381–491 MB | `phys_footprint`; Mac only |

The memory rows are the price of the Mac profile: up to 14 photos in flight, 24 finished chunks waiting
(about 6 MB), and up to 16,384 shared high-pass images (at most 134 MB) during the results build. The
phone profile does none of it.

Details, including the machine's noise, are in [validation-log.md](validation-log.md).

## Validation

See [validation-log.md](validation-log.md).
