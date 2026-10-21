# Feature Specification: Staged Cleanup for Large Libraries

**Feature Branch**: `008-staged-cleanup-at-scale`

**Created**: 2026-10-20

**Status**: Implemented (scan, results and app behavior, tests, Mac exercise); phone numbers still open

**Input**: User description: "On a library of about 30,000 photos the scan fails while the app is in
the background, and it takes a long time to finish, so the user waits too long before seeing anything
useful. Fix both with a staged cleanup, then test the app on the Mac."

**Builds on**: [004-phased-cleaning](../004-phased-cleaning/spec.md), which designed phased cleaning
and had delivered only the free-app video rule. This feature delivers the part of 004 that the 30,000
photo case needs (quick wins, newest-first blocks, results while the scan runs, bounded memory and
detection cost, the user's choices surviving rebuilds) and leaves the rest of 004 (run profile and
governor, step 3 and 4, snapshot on launch, "stop after this step") for later. It also uses
[003-durable-chunked-scan](../003-durable-chunked-scan/spec.md) unchanged, and the macOS app of
[005-all-apple-platforms](../005-all-apple-platforms/spec.md), whose Mac target did not exist and was
built to the minimum needed to run a large scan there.

## What was wrong (measured, 2026-10-20)

Measured on an Apple-silicon Mac with `Packages/CleanupKit/Benchmarks/ScaleBench` (synthetic library
of 30,000 items shaped like the research's model) and with the macOS app on the `large30k` demo
library. No phone was measured: the author's phone was not connected, so the exact way iOS ends the
app in the background was **not observed**. What follows is what the code does at this size, each point
measured.

| # | Finding | Measured | Why it breaks in the background |
|---|---------|----------|---------------------------------|
| 1 | The debug build runs the package unoptimized. `Sharpness.score` costs 184 ms per photo against 2 ms optimized; the whole per-photo analysis 194 ms against 13 ms | results build of 30,000 items 84.6 s (debug) against 0.6 s | The app installed with plain `xcodebuild` is a debug build. A scan of 30,000 photos takes hours, and every rebuild of results is minutes of CPU at full load, which iOS does not allow a background app |
| 2 | Every scan start, resume, quick check and every return to the foreground read all stored items with their fingerprints (`Store.items()`), and results kept every item with them | 644 MB peak for 30,000 items; the launch pipeline 853 MB (004 research); the app at rest after a scan kept about 360 MB | Memory grows with the library. A background process is ended first when the system needs memory, and nothing in the scan loop is at fault: the loop itself stayed at 54 MB |
| 3 | Duplicate confirmation recomputed both high-pass images for every candidate pair, and held every pair in an array | 9.8 million candidate pairs among 27,700 photos of the demo library; results build 281 s (release), peak 625 MB | Minutes of CPU and hundreds of MB at the end of the scan, in a process the system may already be about to suspend |
| 4 | Nothing was shown until the whole scan ended, and an interrupted scan showed nothing at all | first result after the last photo | The wait is dead time, and if the system ends the scan nothing was gained |
| 5 | Sizes of every listed photo were measured after every build by reading each file in full | not measured on a phone | Gigabytes of reads started right after the scan ended |
| 6 | About 4,000 progress events per scan, each one a screen update, a log line and a call to the system's progress display | 3,940 events | Needless work and IPC while backgrounded |

The scan loop itself (chunks, leases, checkpoints) was already flat in memory and time per chunk
(6.8 ms per checkpoint from the first chunk to the last). It is unchanged.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Screenshots and large videos are there at once (Priority: P1)

A person with 30,000 photos taps Scan. Within seconds Home lists their screenshots and their largest
videos with counts and space, before any photo has been opened for analysis, and they can review and
remove them while the rest is checked.

**Independent Test**: `StagedCleanupTests.screenshotsAndVideosAreListedBeforeAnyPhotoIsOpened` (photos
never finish in the test); the `large30k` run on the Mac, where the first rebuild after Start lists
1,386 screenshots and 50 videos with 0 of 30,000 photos checked.

**Acceptance Scenarios**:

1. **Given** a scan has just started, **When** the plan is made, **Then** screenshots and (in the free
   app) videos are stored from their metadata and the first progress event carries a new
   `publishedRevision`, so the app rebuilds and shows them.
2. **Given** a screenshot, **When** the scan reaches it, **Then** its preview is never requested: no
   detector reads a screenshot's analysis (they are listed by kind), so the work would be wasted.
   This is the same rule the free app already applies to videos.
3. **Given** the quick wins were shown, **When** later photos are analyzed, **Then** no screenshot moves
   to another category (004 FR-003; this was already true because no photo detector accepts screenshots).

### User Story 2 - Review while the scan continues (Priority: P1)

The scan checks the newest photos first. After the first 500 photos, then 1,500, 4,000, 6,500 and every
2,500 after that, the duplicates, similar shots and blurry photos found so far are ready. Home says
"Found so far · checked 4,928 of 30,000". The person opens Duplicates and starts cleaning while the scan
goes on. A list they have open never changes; new finds wait behind "N new results. Show" or appear when
they return to Home. What they unselected, the keeper they chose and what they removed survive every
update. When the scan ends the results are those of a one-shot scan of the same library.

**Independent Test**: `StagedCleanupTests` (blocks, revision, newest first), `ReviewIntentTests`
(choices over a rebuild; 007 replaced 008's `ResultsContinuityTests`), and the equality test `resultsFromTheLeanPathEqualResultsFromTheFullReader`;
the `large30k` run, which published results at 512, 1,536, 4,928, 8,960, 13,600, 23,936 and 30,000 photos.

**Acceptance Scenarios**:

1. **Given** a block of photos is finished and saved, **When** the pipeline reports progress, **Then**
   `publishedRevision` has moved and the app rebuilds results from the store.
2. **Given** the person has a category or group open, **When** a rebuild finishes, **Then** nothing on
   that screen changes; the rebuild is held as `pendingBuild` and shown when they return to Home or tap
   the prompt.
3. **Given** the person unmarked a photo, marked another, chose a keeper, or removed photos, **When** the
   next rebuild is shown, **Then** each of those decisions still holds, and removed photos are not listed
   again (`ReviewIntent`, applied over every build; photos removed in this run are dropped by
   `AppModel.removedInSession`). 008 first did this with `ReviewChoices` and
   `ResultsContinuity.merge`; merging with 007 replaced them by `ReviewIntent`.
4. **Given** the scan is running and nothing has been found, **When** Home shows, **Then** it says the app
   is looking, never "Your library looks clean".
5. **Given** the scan ended, **When** the last rebuild is shown, **Then** categories, groups, keepers and
   selection equal those of a one-shot scan, except for decisions the person made.

### User Story 3 - A 30,000-photo scan no longer fails or crawls in the background (Priority: P1)

The scan of a large library, the results at its end, the relaunch after it was ended, and the resume
afterwards use memory in proportion to what is listed, not to the library, and cost seconds, not minutes.

**Independent Test**: `ScaleBench` (release, 30,000 items) and the `large30k` run on the Mac; the
equality and digest checks in the Validation section.

**Acceptance Scenarios**:

1. **Given** 30,000 stored items, **When** a scan is planned (start, resume, quick check), **Then** no
   fingerprint is read: `Store.itemSummaries()` returns metadata only, in slices of 1,000.
2. **Given** 30,000 stored items, **When** results are built, **Then** items are read without feature
   prints, prints are read only for photos with another photo within 60 seconds, and the result equals
   what `items()` would give.
3. **Given** many photos with look-alike fingerprints, **When** duplicates are confirmed, **Then** the
   answer for every pair is the one the plain definition gives, found without recomputing a photo's
   high-pass image per pair and without holding the pairs.
4. **Given** the app is a debug build, **When** the package is compiled, **Then** CleanupKit is
   optimized (`-O`) and the app is not.
5. **Given** a scan that goes on, **When** progress events arrive, **Then** the screen, the log and the
   system's progress display are updated at most about once a second, and every change of state at once.

## Requirements *(mandatory)*

- **FR-001**: The plan MUST store items that need no analysis (screenshots; videos without Pro) before
  the first chunk runs, and MUST report it through `ScanProgress.publishedRevision`. They stay in the
  job, so totals, chunks and 003's guarantees are unchanged.
- **FR-002**: Photos MUST be planned newest first for every new job (stable for equal dates; undated
  last). A job already stored keeps its order (004 D2).
- **FR-003**: Screenshots MUST NOT have their preview requested or analyzed; they are stored as
  `metadataOnly`. The aesthetics score MUST be computed only for a still, not portrait, not long-exposure
  photo whose sharpness is below the blur threshold plus a margin of 0.05: nothing else reads it.
- **FR-004**: The scan MUST bump `publishedRevision` after the first 500 photos, then 1,000, then every
  2,500 (`ScanBlocks`), counted from the job's processed items, also after a resume.
- **FR-005**: Planning, catch-up and resume MUST read `Store.itemSummaries()`; refreshed metadata MUST be
  written with `refreshMetadata`, which leaves the analysis alone; measured sizes with `setSizes` (007; one query per 500 ids).
- **FR-006**: The app MUST build results with `ResultsLoader` (items without feature prints; prints for
  `SimilarShotsDetector.photosThatMayNeedFeaturePrints` only). The result MUST equal the builder's result
  over `items()`.
- **FR-007**: `CleanupResults.items` MUST hold only listed items, without their miniature and feature
  print (`LibraryItem.withoutFingerprints`). Nothing may write such an item back to the store.
- **FR-008**: Candidate pairs MUST be streamed, not collected. Confirmation MUST give the answer of
  `detailSimilarity >= thumbprint && meanAbsoluteDifference <= brightness` for every pair (`ThumbprintMatcher`).
- **FR-009**: The app MUST show results as `publishedRevision` moves; hold them while a list is open
  (004 FR-010); apply the person's decisions over every rebuild (004 FR-011); and not rebuild more than a
  third of the time (a pause of twice the last build between rebuilds).
- **FR-010**: Real file sizes MUST NOT be measured after a rebuild except for videos, and MUST NOT be
  measured while a scan runs; photos are measured, at most 300 at a time, when their category is opened.
- **FR-011**: Progress events during a scan MUST be spaced by `minProgressInterval` (250 ms in the app);
  the first event, the event after every chunk, and every change of state are never held back. The
  continued-processing task and the Mac Dock tile MUST be updated at most once a second.
- **FR-012**: The package MUST be compiled with optimization in debug builds.

## Decisions

1. **Only decisions are carried over, not shown keepers.** 004 FR-012 says a keeper the person has seen
   must not change. Pinning every shown keeper would make the final results differ from a one-shot scan
   (004 FR-014) and would hide a better copy found later. So only a keeper the person *chose* is kept. A
   keeper that was merely listed may change when a better copy is found; the list the person has open
   never changes under them.
2. **The deep Vision work is not deferred yet.** Feature print and face quality are needed only for
   photos with a neighbour within 60 seconds (about a third), which could save about a third of the
   analysis (6.4 of 13 ms on the Mac). It needs a signal mask on stored items and a repair rule for
   neighbours that arrive later, and a phone measurement of how much of the per-photo time is Vision at
   all. Left for 004 T012/T013.
3. **Chunk size and width stay 32 and 4.** The chunk boundary costs about 12% of the time at 40 ms per
   preview (measured); raising the width or the chunk without the run profile (004 US3) risks heat.
4. **Quick wins start when the person taps Scan**, not at launch (004 FR-001 says at launch). A first-launch
   metadata pass before the first tap would read the whole library without being asked (001 FR-005a).

## Success Criteria

| | Before | After | How measured |
|---|--------|-------|--------------|
| First results after Start | after the last photo | screenshots and videos at once, duplicates and blurry after 512 photos (4 s on the Mac) | `large30k` trace |
| Results build, 27,700 photos, look-alike set | 281.5 s, peak 625 MB | 7.0 s, peak 312 MB, identical result digest | `ScaleBench --open` |
| Reading stored items for a plan | `items()` 644 MB peak | `itemSummaries()` 94 MB peak, 1.8 s | `ScaleBench` |
| Per-photo analysis, debug build | 194 ms | 12.8 ms | `ScaleBench --stages` |
| Results build, 30,000, debug build | 84.6 s | see Validation | `ScaleBench` |
| Progress events per 30,000 scan | 3,940 sent to the screen | at most about 4 a second, and one a second to the system | trace |

## Validation

See [validation-log.md](validation-log.md).
