# Data Model: Phased Cleaning for Large Libraries

All changes are additive and optional, so SwiftData's lightweight migration opens an existing
store unchanged (003 R6). Nothing here holds photo content: only identifiers, masks, counts,
states, and the saved result structure.

## ScanChunk (stored as `ScanChunkRecord`, extended)

| Field | Type | Meaning |
|---|---|---|
| `phase` | Int8? | step the chunk belongs to: 0 legacy full analysis, 2 photos, 3 similar shots, 4 refinement. Nil reads as 0. Step 1 has no chunks (it is an idempotent diff). In the free app, videos never get chunks. |
| `block` | Int32? | block index within the step, for publishing at boundaries. Nil for legacy chunks. |

Eligibility and ordering: the loop runs the lowest phase with an unfinished chunk, in sequence
order. A chunk is only planned for items that lack the signals its phase produces at the current
version, so a later phase computes only what is missing (FR-028).

## LibraryItem (stored, extended as `LibraryItemRecord`)

| Field | Type | Meaning |
|---|---|---|
| `signals` | Int16? | bit mask of what is stored: metadata, dHash, thumbprint, sharpness, aesthetics, featurePrint, faceQuality, sizeMeasured. Nil on rows from before this feature, read as all present when the analysis source is not "not scanned". |
| `analysisVersion` | Int8? | version of the pixel recipe (hash, thumbprint, sharpness). A change invalidates only those bits. Nil reads as 1. |
| `featurePrintRevision` | Int8? | the Vision request revision that produced the print. A print is comparable only to one of the same revision; a different revision today makes the distance infinite without saying why. |

`Analysis.featurePrint` stays non-optional; empty still means "not available", and `signals`
says whether it was never tried or tried and failed. A change of `modificationDate` clears the
mask (existing behaviour of the planner).

If spike S1 chooses a split entity, the two blob columns move to `ItemBlobRecord`
(`assetID` unique, `thumbprint`, `featurePrint`). New items write only the new record; old rows
keep their columns and are read as a fallback.

## ScanSession (stored, extended as `ScanSessionRecord`)

| Field | Type | Meaning |
|---|---|---|
| `planSteps` | Data? | encoded `CleaningPlan`: per step state, planned and done counts, foundCount, started and finished times |
| `order` | String? | `newestFirst` or `oldestFirst`; nil means oldest first (jobs from 003) |
| `stopAfterStep` | Int8? | set by "Stop after this step" |
| `effort` | String? | the user's setting at start, for the record |

> **Note (2026-10-18): superseded by [specs/007-persistent-session](../007-persistent-session/data-model.md).**
> `ResultsSnapshotRecord`, `itemsRevision` and `seenGroups` below are replaced. The saved results are
> one `StateRecord` row with key `results` and a `basedOnRevision`. The store revision is
> `StoreMetaRecord.resultsRevision`, bumped only by writes that change what results are built from (a
> new or changed item, a removal, a keep mark, a measured size replacing an estimate), not by every item
> write and not by scan bookkeeping. `seenGroups` lives in the `decisions` payload, and the continuity
> of the person's choices is delivered by asset-keyed overrides replayed by one applier on every
> publish. The two sections below describe the earlier plan and are kept for history.

## ResultsSnapshot (new, `ResultsSnapshotRecord`, one row)

| Field | Type | Meaning |
|---|---|---|
| `epoch` | Int64 | increases at every publish |
| `itemsRevision` | Int64 | the store revision the snapshot was built from; a mismatch means stale |
| `builtAt` | Date | |
| `body` | Data | encoded categories, each with groups: member ids, keeper ids, confidence, default selection; plus the per-category "checked N of M" |
| `seenGroups` | Data | which groups the user has had on screen, with the keeper they saw, for continuity |

Size at 30,000 photos: about 6,000 to 8,000 groups, under 1 MB (estimate). Read at launch
instead of building. Item rows for display are loaded by id when a category opens.

## Store revision (new, in a small `StoreMetaRecord`)

An integer bumped inside every transaction that writes or deletes items. Compared with the
snapshot's `itemsRevision` to tell whether a rebuild is needed.

## CleaningPlan (in memory, mirrored in `planSteps`)

```text
CleaningPlan
├── steps: [Step]        // overview, photos, similarShots, refinement
├── currentStep
├── order
└── Step { kind, state, planned, done, foundCount, foundBytes, waitingReason?, estimatedRange? }
StepState: waiting | running | paused(reason) | done | notRun | stoppedAfter
```

## RunProfile, DeviceCapabilities, Conditions (in memory only)

```text
DeviceCapabilities { physicalMemory, activeCores, hasNeuralEngine, formFactor }
Conditions { thermal, lowPowerMode, power: mains|battery(level)|unknown,
             memoryWarnings, availableMemory?, userReviewing, appActive }
RunProfile { width, visionGate, chunkSize, blockSizes, qos, deepWork: fused|deferred,
             autoSteps: Set<StepKind>, throttle: ThrottleReason? }
ThrottleReason: warm | lowPower | waitingForPower | battery | memory
```

None of these is stored. The only stored device fact is the measured speed (items per second
and the date) used for the time estimate and shown in Settings.

## ScanPauseReason and ScanProgress (extended)

`ScanPauseReason` gains `lowPower`, `waitingForPower`, `battery`, `memory`. All four resume on
their own when the condition clears (like `backgroundLimit`), except that `waitingForPower` and
`lowPower` also end on "Run now". `ScanProgress.isThermalPaused` stays for compatibility and
`ScanProgress.throttle` carries the reason for any reduction.

## Compatibility

- Existing rows: `signals`, `analysisVersion`, and `featurePrintRevision` are nil; read as
  complete at version 1, so nothing is rescanned.
- A 003 job in progress finishes as a single legacy step ("Photos"), oldest first.
- Delete All Data removes plan data, the snapshot, the revision, and chunks, as in 001 FR-018.
