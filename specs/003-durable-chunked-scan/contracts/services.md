# Contract: Services (delta to 001 and 002)

## Scanner (unchanged shape)

`startFullScan`, `quickCheck`, `pause(reason:)`, `resume`, `stop` keep their signatures.
Behaviour changes:

- `startFullScan()` continues an unfinished job from its first unfinished chunk; adopts
  a session saved by an app version without chunks.
- `quickCheck()` returns the saved progress and does no work while a job is unfinished.
- `ScanPipeline.init` takes `chunkSize` (was `saveEvery`) and `policy: ScanRetryPolicy`.

## Store (additions)

```swift
func sessions() async throws -> [ScanSession]                    // newest first
func scanAttempts(for assetIDs: [String]) async throws -> [String: Int]
func createJob(_ session: ScanSession, chunks: [ScanChunk]) async throws   // one transaction
func chunks(job: UUID) async throws -> [ScanChunk]               // by sequence
func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) async throws
func checkpoint(items: [LibraryItem], chunk: ScanChunk, session: ScanSession) async throws // one transaction
func deleteChunks(job: UUID) async throws
```
`deleteAllData` and session pruning also delete chunks.

## PhotoLibrary (addition)

```swift
func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata]   // missing ids are omitted
```
A default implementation filters `fetchAllItems()`; PhotoKit fetches by identifier.

## Guarantees (each has a unit test in `DurableScanTests`)

- **G1 Checkpoint is atomic**: results, chunk state and session counters are saved in
  one `modelContext.save()`.
- **G2 Crash loses one chunk at most**: a chunk left `running` by another process is
  re-run; everything in `done` chunks and set bits is not re-analyzed
  (`crashLosesOnlyTheChunkInFlight`).
- **G3 Resume does not re-diff before analysis restarts**: when the first preview of a
  resumed job is requested, `fetchAllItems` has not been called; one catch-up diff runs
  after the last chunk to pick up photos added or changed meanwhile
  (`resumeAfterPauseDoesNotRediffTheLibrary`).
- **G4 Reclaim rules**: normal → isolate → suspect → poison; released chunks untouched;
  crash budget stops the job (`reclaim*`, `crashBudgetStopsTheJob`).
- **G5 Retries are bounded and lossless**: failing items run again up to 3 times with
  delays; the rest of the chunk is kept (`transientFailuresAreRetriedWithoutLoss`,
  `itemThatAlwaysFailsIsGivenUpOn…`).
- **G6 Timeouts never stall**: a hung preview ends the item after `itemTimeout`
  (`hungPreviewTimesOut…`).
- **G7 Release before waiting**: after `pause(reason:)` returns, no chunk is `running`
  and the store holds every processed item (`pauseReleasesTheChunkBeforeWaiting`).
- **G8 Deleted items are skipped silently** (`deletedItemsInAPendingChunk…`).
- **G9 Catch-up after a resume from the store** (any resume in a new process: after a
  crash, a pause, or a background expiration): items added or changed meanwhile are
  analyzed before the job completes; items the job gave up on are not retried
  (`itemsAddedDuringAnInterruptionAreCaughtUp`, `itemsAddedWhileAJobWasPausedAreCaughtUp`,
  `itemsChangedAfterTheirChunkFinishedAreAnalyzedAgain`).
- **G13 A job ends in one transaction**: saving an ended session removes its chunks in
  the same save (`endingASessionRemovesItsChunksInTheSameSave`).
- **G14 A failed write leaves nothing behind**: store writes roll back on error
  (`aFailedCheckpointLeavesNothingBehind`).
- **G15 Crash blame lands on the item in flight**, saved before it starts
  (`reclaimBlamesTheItemInFlightNotAnEarlierFailure`).
- **G16 Heat or a pause never causes items to be skipped**
  (`aHeatFlickerAtAnyPointNeverSkipsItems`).
- **G10 Progress never decreases across an orderly pause and resume**
  (`progressNeverDecreasesAcrossResume`); after an unexpected exit it is at most one
  chunk lower.
- **G11 A pause during a heat wait is reported and acknowledged**
  (`pausingDuringAHeatPauseIsReportedAndAcknowledged`).
- **G12 Pause saves only checkpointed counters and releases the chunk**
  (`pauseWhileItemsAreInFlightSavesOnlyWhatIsStoredAndReleasesTheChunk`); a user pause is
  never turned into an automatic one (`aPauseTheUserAskedForIsNotTurnedIntoAnAutomaticOne`).
