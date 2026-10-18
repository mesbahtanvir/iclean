# Research: Durable Chunked Scan

Design chosen with a three-way design panel (minimal evolution, persisted job queue,
crash-safety first) scored by three judges on robustness, simplicity, testability,
performance and extensibility, then synthesized and slimmed to fit the codebase.

## R1. Unit of durability: a chunk of 32 items with a done mask

- **Decision**: `ScanChunk` holds up to 64 asset ids and a 64-bit `doneMask`; the
  pipeline uses 32. Results and bits are saved in one transaction per chunk
  (`Store.checkpoint`). A kill loses at most the unfinished part of one chunk, about
  1.6 s of work at the 001 target rate.
- **Rationale**: one row per chunk (about 1.3 KB) instead of one row per item keeps
  write amplification low; the mask makes partial progress inside a chunk resumable
  without extra rows.
- **Alternatives**: per-item task rows (30× the rows); larger chunks (more lost work).

## R2. Crash accounting by lease owner

- **Decision**: a chunk is written as `running` with the process's `incarnation` UUID
  before work starts. On launch, `ScanReclaim` treats a chunk still `running` as left by
  a process that died: `crashes += 1`, switch to isolate mode (one item at a time, saved
  after every item), then suspect the first unfinished item, then set it aside after a
  second death on the same item (`scanFailure = .crashed`). Pause, stop, thermal and
  background expiration release the chunk (`pending`, owner nil) before waiting, so
  those are never counted.
- **Rationale**: the app cannot know why it died; the owner token separates deaths
  from orderly exits, and the three-step escalation isolates a true crasher within three
  launches while an unlucky innocent item needs two deaths on the same index.
- **Alternatives**: counting every relaunch (false poison on jetsam); write-ahead
  in-flight markers per item (more writes, same information in isolate mode).

## R3. Retries with bounded attempts and delays

- **Decision**: `ScanRetryPolicy`: 3 attempts per chunk, delays 2 s then 8 s, per-item
  limit 20 s, crash budget 5 per job, and at most 6 later full scans retry an item that
  ended unanalyzed (`LibraryItem.scanAttempts`, stamped at checkpoint from the stored
  count). A chunk that fails keeps its finished bits and is re-queued with `notBefore`;
  only the failing items run again. Waiting for a retry ends at once on pause or stop.
- **Rationale**: transient failures (engine not ready, memory) pass within seconds;
  anything that fails three runs is not transient. Cross-scan retries also cover
  cloud-only items that may become local later.
- **Alternatives**: unbounded retries (loops); per-item attempt rows (more writes).

## R4. Per-item timeout that never awaits the hung task

- **Decision**: `Timeout.run` races the work task against a sleep; the loser is
  cancelled but never awaited, and a lock-guarded `Once` resumes the continuation
  exactly once. A timeout counts as one failed attempt for the chunk.
- **Rationale**: PhotoKit and Vision may ignore cancellation; structured task groups
  would wait for them and stall the scan.
- **Alternatives**: `withThrowingTaskGroup` racing (hangs on uncancellable children).

## R5. Resume reads chunks, not the library

- **Decision**: an active session with chunks is resumed from `Store.chunks(job:)`; no
  `fetchAllItems`, no item load. Each chunk fetches current metadata for its own ids
  (`PhotoLibrary.fetchItems(withIDs:)`), skipping ids no longer in the library. After the
  last chunk of any job resumed from the store (after a crash, a pause, or a background
  expiration), one catch-up diff adds chunks for items added or changed meanwhile before
  the job completes. It plans like a quick check, so items the job gave up on are not
  retried within the same job.
- **Rationale**: FR-004 (100k items resume in under 2 s) rules out the full diff;
  FR-011 still needs one diff, but only after an interruption and only once.
- **Alternatives**: always diff (slow); never catch up (new items wait for the next
  scan).

## R6. Migration

- **Decision**: additive only: one new entity, optional columns on two shipped
  entities, no renames, so SwiftData infers a lightweight migration. A session from an
  older version with no chunks is adopted: its processed count becomes
  `baseProcessed` and the remainder is planned into chunks (FR-014).
- **Rationale**: no `VersionedSchema` and no rescan for existing users.
- **Verified**: `StoreMigrationTests` opens `Fixtures/previous-store`, a store written
  by the previous schema, with the current schema; a mutant with a required column and no
  default makes it fail with CoreData error 134110. The fixture is made by
  `scripts/make-previous-store-fixture.swift` in its own process, because defining the old
  model classes inside the test process crashes CoreData (same entity names).
- **Still to observe**: the first launch over the real store on the user's phone (it was
  locked); check that Settings → Recent Scans opens without error.

## R7. Stop semantics

- **Decision**: `stop()` ends the job (`stopped`) and deletes its chunks; the next full
  scan plans the remainder from the store diff, as in 001. Pause, crash and background
  expiration keep the chunks.
- **Rationale**: Stop is an explicit end; keeping its chunks would make "Scan Again"
  silently continue an old plan.
