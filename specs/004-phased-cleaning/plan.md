# Implementation Plan: Phased Cleaning for Large Libraries

**Branch**: `004-phased-cleaning` | **Date**: 2026-10-18 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/004-phased-cleaning/spec.md`

## Summary

A scan becomes a plan of four steps, each a kind of piece in the durable job from 003.
Step 1 reads metadata only and lists screenshots and large videos (by file size) in seconds.
Step 2 is the photo pass: newest first, in blocks, with a first block of 500 photos,
computing hash, thumbprint, and sharpness from the one 512 px preview the pipeline already
fetches, plus the feature print for photos that have a time neighbour when the device can
afford it. Step 3 is that feature-print work, deferred on weak devices. Step 4 refines picks
lazily. In the free app videos are never analyzed; video analysis is a Pro feature (one-time $2,
not built yet; spec FR-004a).

Results are published at every block boundary as a snapshot built by the same builder as
today, so the final results equal a one-shot scan by construction. A continuity rule carries
the user's selections, keepers, and removals from one snapshot to the next. The last snapshot
is saved, so launch reads it instead of rebuilding from all items. A pure function turns
device capabilities and current conditions into a run profile (width, chunk size, block size,
which steps run on their own), and a small governor applies it between pieces. Three measured
scale hazards are bounded: loading every stored blob, unbounded same-minute similar-shot
matching, and unbounded fingerprint-cluster confirmation.

The design combines two proposals judged by independent research: ordering the work by
value for cost (steps), and bounding the work in memory and time (blocks). It does not adopt
per-date windows with group ownership across windows, the hardest part of the other proposal
(see [research.md](research.md) R1).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK

**Primary Dependencies**: unchanged (SwiftData, PhotoKit, Vision). No new frameworks on iOS.
Power and battery signals use `UIDevice` and `ProcessInfo`; the Mac signals belong to spec 005.

**Storage**: SwiftData, additive and optional only, so lightweight migration applies (003 R6):
`phase` and `block` on `ScanChunkRecord`; `signals` and `analysisVersion` on
`LibraryItemRecord`; plan fields on `ScanSessionRecord`; one new `ResultsSnapshotRecord`;
a store revision counter. Possibly a separate blob entity, decided by spike S1
(see [data-model.md](data-model.md)).

**Testing**: Swift Testing in `CleanupKit` (table-driven `RunProfileTests`, `GovernorTests`
with a manual clock, `PhasedScanTests`, `ResultsContinuityTests`, `ScaleGuardTests`,
extended `DurableScanTests` per step); a 30,000-item fake-library scenario; the Release
benchmark in `research-prototypes/bench30k` promoted to a maintained target (T003); XCUITests
with launch arguments for injected conditions (`-iclean-conditions`, `-iclean-device`);
on-device timing through the baseline library harness.

**Target Platform**: iOS 18.0+ iPhone first; the policy code is platform-neutral for spec 005.

**Project Type**: mobile-app (single iOS app plus one local Swift package), unchanged

**Performance Goals**: SC-001 to SC-006 in the spec. Reference figures measured on one Apple
M4 Max, Release, synthetic data (research R5): results build for 30,000 items 0.67 s and
120 MB peak; loading 30,000 stored items 1.25 s and 569 MB resident; launch pipeline 853 MB
peak; 3,000 same-minute photos 42.8 s.

**Constraints**: preview size 512 px for every device (FR-023); chunk size at most 64 (the
done mask is 64 bits); no network; a kill repeats at most one piece in every step (003).

**Scale/Scope**: about 10 new files and 8 touched files in `CleanupKit`; 6 touched in the app.

## Constitution Check

| Principle | Status |
|---|---|
| I. Local-only data | Pass. New records hold identifiers, counts, states, and the saved snapshot. |
| II. No outbound network | Pass. No network API is added. Cloud-only photos stay unreachable by design. |
| III. Offline-safe dependencies | Pass. No new dependency. |
| IV. User owns their data | Pass. Delete All Data removes plan, snapshot, and chunk records; removal still needs the confirmation sheet. |
| V. Verifiable privacy | Pass. `scripts/check-no-network.sh` and the no-network UI plan run unchanged. |

### Data & Network statement

Touches: photo metadata (already stored), analysis fingerprints (already stored), and new
plan and snapshot records. Stored in the existing on-device SwiftData store with the same
file protection. Network access: none. Device facts read for pacing (memory, cores, thermal,
power, Low Power Mode) stay in memory and are not stored beyond the measured speed in
Settings, which holds a number and a date.

## Design

### D1. Steps

| Step | Computes | Needs | Preview | Notes |
|---|---|---|---|---|
| 1 Quick wins | screenshot flag, subtypes, duration, pixel size; estimated video size, then real file size for the top ~100 videos | nothing | none | One metadata enumeration without the album walk (albums are display-only and move to the background). Final for screenshots (FR-003). No video frame is read in the free app (FR-004a). |
| 2 Photos | hash, thumbprint, sharpness; aesthetics only below the blur threshold plus a margin; feature print for photos with a 60 s neighbour when the profile fuses | step 1 | 512 px, unchanged | Newest first, in blocks. Chunks of the profile's size. Stills and Live Photos only; videos are skipped in the free app. |
| 3 Similar shots | feature print for photos with a 60 s neighbour | step 2 | 512 px | Runs only when the profile defers deep work. Waits for power on weak devices. |
| 4 Refinement | face quality for groups whose top two sharpness values are within the tie band; real sizes for items on screen | steps 2 and 3 | 512 px | Lowest priority; also on demand when a group is opened. Never changes a keeper the user has seen. |

Why a feature print per neighbour and not per photo: in the model library only about 35%
of photos have another photo within 60 seconds, so feature prints fall by about two thirds
and Vision requests overall (feature print, aesthetics, face quality) by about 86% against
today's every-photo analysis (research R2). Time saved is smaller than that suggests,
because preview fetch and decode are likely the larger cost on a phone; the plan therefore
fuses step 2 and the feature print when the profile allows, to avoid a second fetch, and
measures before tuning (spike S2).

`Analysis.featurePrint` stays a non-optional `Data`. An empty value already means "not
available" to `SimilarShotsDetector`, which falls back to the thumbprint. The new `signals`
mask tells "not computed yet" apart from "tried and failed".

### D2. Blocks

Step 2 and 3 chunks are planned newest first. A block is a run of whole chunks. Block sizes
are 500, then 1,000, then the profile's size (2,500 / 5,000 / 10,000 / the whole library).
A block boundary is where results are published (D4). Chunk order inside a block follows the
planner; durability, retry, reclaim, and catch-up are unchanged because they key on chunks.
Existing 003 jobs keep their oldest-first order; only new jobs are newest first.

### D3. Run profile and governor

A pure function `runProfile(capabilities, conditions, effort)` returns a `RunProfile`:
width, Vision gate, chunk size, block size, quality-of-service class, which steps may start
on their own, and a throttle reason when something was reduced. It is the unit under test.

Seed from capabilities, never from a model table:

| Profile | Seed rule | Width | Vision gate | Chunk | Blocks after ramp | Deep work |
|---|---|---|---|---|---|---|
| compact | under 4 GB, or no Neural Engine | 2 | 1 | 16 | 2,500 | deferred (step 3) |
| standard | under 8 GB | 4 | 2 | 32 | 5,000 | fused |
| fast | 8 GB or more, phone, iPad, or headset | 6, at most cores minus 1 | 2 | 48 | 10,000 | fused |
| max | Mac with 16 GB or more | at most 10, cores minus 2 | 2 | 64 | whole library | fused |

The seed is a ceiling until measured. Widths are provisional: the only measurement is on an
M4 Max, where Vision feature prints saturate at 2 lanes and CPU-only is about 8 times slower
(research R3). Spike S2 fits them on real devices.

Conditions then reduce the profile, never raise it above the seed (SC-007):

| Condition | Effect |
|---|---|
| Thermal fair | width halved (minimum 1), utility class |
| Thermal serious or critical | pause at the piece boundary, resume after fair for 30 s (spec 002) |
| Low Power Mode | width at most 2 (1 on compact); steps 3 and 4 do not start on their own |
| On battery below 20% | pause all but step 1 |
| Not on power | step 3 waits for power or "Run now" on compact; on other profiles it runs from 30% |
| Memory warning | width halved for 60 s, caches flushed; two within 5 minutes lower the profile one level for the session |
| Memory headroom under the larger of 120 MB and 8% of physical memory | checkpoint and pause |
| User is reviewing | width at most 2 at utility class (to be checked in spike S3) |
| Effort Gentle / Full speed | one level down / ignore power and Low Power Mode only |

Thermal and memory-critical always win over the effort setting. Step down is immediate and
step up needs 60 s at the better level (hysteresis). The governor owns timers and is read by
the pipeline after every piece and after each item for thermal. `ConditionsProvider` is a
protocol with live and fake implementations (an `AsyncStream` of conditions), and a manual
clock replaces `Date` and `Task.sleep`, so a 30-minute thermal ramp runs in milliseconds.

### D4. Results while running

1. At each block and step boundary the app builds a snapshot from the items stored so far with
   the same `ResultsBuilder` as today, off the main thread, and publishes it with an epoch.
   Equality with a one-shot scan holds by construction (FR-014).
2. **Frozen views.** A category screen captures its group list when opened. Later snapshots
   change Home counts but not an open list; a "12 new" prompt reveals them.
3. **Continuity.** A new group that shares a member with a group the user has already seen
   inherits that group's keeper (if still a member) and the user's selection overrides for the
   shared members. `AppModel.apply` today sets `selection = new.defaultSelection`, which would
   discard the user's choices; it becomes `selection = (old ∩ live items) ∪ defaults of items
   that were not in any earlier snapshot`. Explicit deselections are remembered separately so a
   default never re-selects them. Removed and keep-marked items are excluded as today.
4. **Honest labels.** Row text is "found so far, checked N of M" until the steps feeding the
   category are done or stopped. The empty state is suppressed until then (FR-013).
5. **Not adopted: an incremental results engine** that persists match edges and updates
   groups per chunk. It is the end state in the roadmap and the largest piece of new logic.
   Stage S5 adds it only if measurements after S3 and S4 show snapshot rebuilds are too slow or
   too large on the target devices (research R4).

### D5. Scale guards

| Hazard (measured, M4 Max, Release) | Guard |
|---|---|
| Loading 30,000 stored items: 1.25 s, 569 MB resident, 853 MB in the launch pipeline | Slim items for detection (hash, scalars, metadata); blobs fetched by id only for candidate pairs; snapshot saved so launch does not build. Spike S1 chooses the mechanism. |
| 3,000 photos in one minute: 4.7 M similar-shot comparisons, 42.8 s | Compare each photo with at most K following neighbours inside the 60 s window (K = 12, validated against the accuracy suites). Chains of adjacent frames still join into one group. |
| 15% clustered fingerprints: 77 k candidate pairs, 1.36 s (5 times ordinary) | Cap confirmations per photo and in total; skip near-constant fingerprints; the cap is a documented difference only for pathological libraries. |
| Debug builds: 95 s to build results at 30,000 on an M4 | Not a product path. 30,000-item tests and benchmarks run in Release; a debug-only guard logs when a build exceeds 5 s. |

### D6. Home and Settings

Home shows a Cleanup plan list above the category rows: Quick wins, Photos, Similar shots,
Best-shot refinement. Each row has a state, progress, an estimated range, and
"Review" once it has results. The scanning screen collapses into the running row. The status
line explains waits ("Waiting for your iPad to be charging", "Low Power Mode is on") with a
"Run now" button. Settings gains Scan speed (Automatic, Gentle, Full speed) and shows
"Speed measured: N photos per second, checked on a date" once known. All strings use the
device's own noun and go through the string catalog. See [contracts/ui.md](contracts/ui.md).

### D7. Migration

All additions are optional. For stored items with an analysis source other than not-scanned,
`signals` is read as all-present at version 1, so no rescan follows the update. A 003 job in
progress finishes as a single legacy "photos" step; the plan row says so.

## Project Structure

### Documentation (this feature)

```text
specs/004-phased-cleaning/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── tasks.md
├── contracts/
│   ├── services.md
│   └── ui.md
├── checklists/requirements.md
└── research-prototypes/bench30k/   # the Release/Debug scale benchmark behind research R5
```

### Source Code (repository root)

```text
Packages/CleanupKit/Sources/CleanupKit/
├── Scanning/
│   ├── CleaningPlan.swift         # new: steps, states, progress
│   ├── PhasePlanner.swift         # new: chunks per step, newest first, blocks, candidates
│   ├── RunProfile.swift           # new: capabilities, conditions, pure runProfile()
│   ├── ScanGovernor.swift         # new: hysteresis, conditions stream
│   ├── ScanPipeline.swift         # changed: steps, dynamic width, block events
│   └── ScanPlanner.swift          # changed: per-step eligibility from signals
├── Analysis/Analyzer.swift        # changed: staged analysis (basic, deep)
├── Grouping/SimilarShotsDetector.swift, DuplicatePhotoDetector.swift  # changed: scale guards
├── Results/ResultsBuilder.swift   # changed: slim input, snapshot output, continuity input
├── Results/ResultsSnapshot.swift  # new: saved structure and continuity map
├── Store/Store.swift, SwiftDataStore.swift, LibraryItemRecord.swift,
│   ScanChunkRecord.swift, ScanSessionRecord.swift, ResultsSnapshotRecord.swift  # changed / new
└── Models/Types.swift             # changed: pause reasons, throttle reason, signals
iclean/
├── App/AppModel.swift             # changed: snapshots, continuity, plan state
├── App/AppEnvironment.swift       # changed: governor and conditions provider
├── App/ConditionsProvider+iOS.swift  # new: thermal, Low Power, battery, memory warnings
└── Features/Home, Scanning, Category, Settings   # changed: plan list, prompts, labels
Packages/CleanupKit/Tests/CleanupKitTests/Unit/   # new test files listed under Technical Context
```

## Delivery stages

Each stage ships on its own and has an exit measurement.

| Stage | Contents | Exit |
|---|---|---|
| S0 | Spikes S1 to S3 and the on-device timing harness; promote the benchmark; scale guards for same-minute and clustered input | Real per-stage timings on the author's phone; SC-006 met on the Mac |
| S1 | Step 1 quick wins (metadata only) and its UI | SC-001 on the phone |
| S2 | Phase-tagged chunks, newest-first blocks and ramp, snapshots at block boundaries, frozen views, continuity, honest labels, plan list | SC-002, SC-008, SC-009 |
| S3 | Run profile, governor, conditions provider, fused versus deferred deep work, power and thermal rules, Settings override | SC-007 and the thermal and power scenarios in quickstart |
| S4 | Slim loading, saved snapshot, launch path, memory budget, 100,000-item test | SC-004, SC-005 |
| S5 (only if measured) | Incremental results engine | Snapshot rebuild no longer meets SC-004 or SC-005 |
| S6 | Stop after a step and continue later | Story 5 scenarios |

## Risks & open items

- Every phone number is an extrapolation from one Mac. The first task is to measure preview
  fetch and per-stage cost on a real phone. If fetch dominates, fusing becomes the default on
  every profile and step 3 mostly disappears; the plan tolerates both.
- Newest-first changes the meaning of `lastProcessedAssetID` and the order the resume tests
  assume. New jobs record their order; old jobs are unchanged.
- Continuity by member overlap can attach a user's choice to a group that has grown or merged.
  The rule is deterministic and unit-tested, and a merge of two seen groups keeps the older
  group's keeper.
- A snapshot built from partial items can show a duplicate pair whose twin arrives in a later
  block as a larger group. The open-list freeze and keeper continuity cover what the user sees;
  counts on Home may rise. The label says "found so far".
- Screenshots final in step 1 changes 001 FR-002 and FR-004a and some accuracy and flow tests.
  Decision 1 in the spec; tests listed in tasks T040.
- Video analysis is Pro only (FR-004a, Decisions 6 and 7), so the free app has no Duplicate
  Videos category: its detector and flow tests stay in the code behind a Pro switch, and the
  baseline library checks the free app only (the video copies are listed under Large Videos
  like any other video).
- The 12-neighbour cap and the confirmation caps change detection on pathological libraries.
  They are validated on the accuracy suites and the baseline bursts before shipping.
- "User is reviewing: width at most 2" may be unnecessary or insufficient; spike S3 measures
  scrolling smoothness with a scan running before it is kept.
- Thermal fair halving contradicts the text of 002; the amendment is recorded in the spec.
- No unattended background step: a person who starts a scan and leaves the app gets only the
  continuation 002 already provides; deep steps on weak devices wait for them.

## Complexity Tracking

| Added piece | Why it is needed | Simpler option rejected |
|---|---|---|
| Run profile and governor | One tuning cannot suit a 3 GB phone and a 16 GB desktop; thermal and power rules need one testable home | Hard-coded widths per platform: untestable and wrong on the middle devices |
| Continuity rule | Without it an update undoes the user's choices | Rebuild and reset: loses selections (the behaviour of `apply` today) |
| Saved snapshot | Removes the launch-time rebuild and its memory | Rebuild at launch: measured 853 MB and 2 s on a Mac, worse on a phone |
| Skip: incremental results engine | Only if measurements require it | Built first: large and unproven |
