# Feature Specification: Durable Chunked Scan

**Feature Branch**: `003-durable-chunked-scan`

**Created**: 2026-10-17

**Status**: Draft

**Input**: User description: "The task run should be durable, if it fails in the middle it still should be resumable at the middle, so the task management has to be retriable, task need to be split into smaller chunks."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) (FR-005, FR-006, edge cases
"huge libraries" and "app closed mid-scan") and [002-background-scan-progress](../002-background-scan-progress/spec.md)
(pause reasons, background continuation). Today a scan saves progress every 100 items and
resumes by comparing the whole library with everything stored. This feature makes the scan a
saved job made of small pieces of work, each with its own state and retry count, so that any
failure loses at most one piece and nothing can block the run.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The scan survives anything and continues from the middle (Priority: P1)

A user starts a scan of a large library. Halfway through, the app crashes, the user swipes it
away, the battery dies, or iOS ends the background allowance. The next time they open iclean,
Home offers Resume (as today), and the scan continues from where it was: the work that has to
be repeated is at most one small piece, and the "N of M checked" count carries on from the
saved value rather than starting over or jumping backwards.

**Why this priority**: This is the request. A long scan that can lose minutes of work on an
interruption is one users will not trust to run unattended.

**Independent Test**: Kill the app at random points during a scan of a few thousand demo
items, relaunch, resume, and confirm that every run completes, that the items re-analyzed
after each kill never exceed one piece, and that stored results and saved progress always
agree.

**Acceptance Scenarios**:

1. **Given** a scan has completed some pieces of work, **When** the app is killed and
   relaunched, **Then** Resume continues at the first unfinished piece and re-analyzes at
   most one piece's worth of items.
2. **Given** the app is killed between finishing a piece and saving it, **When** the scan
   resumes, **Then** that piece is redone and the final results are identical to an
   uninterrupted scan.
3. **Given** a scan that was paused, stopped, or ended by the system resumes, **When** the
   progress is shown, **Then** the count is never lower than the last value the user saw.
   After an unexpected exit (crash, kill, battery), the count restarts from the last saved
   piece, so it can be lower by at most one piece (32 items).
4. **Given** a library of 100,000 items with a scan interrupted near the end, **When** the
   user taps Resume, **Then** analysis starts again within 2 seconds, without a full
   comparison of the library against stored results.

---

### User Story 2 - A problem photo never blocks the scan (Priority: P2)

One photo makes analysis crash or hang every time (a corrupt file, an unusual format). Today
a crash on the same item on every relaunch would stop the scan from ever finishing. With this
feature, a piece that keeps failing is split into smaller pieces, down to single items; an
item that fails repeatedly is set aside, counted as "could not be checked", and the rest of
the scan proceeds.

**Why this priority**: One bad file must not cost the user the whole feature. This is what
makes "resumable" also mean "finishable".

**Independent Test**: Seed a demo library with one item whose analysis throws, one that
hangs, and one that crashes the process on every attempt; confirm the scan completes with
exactly those items reported as not checked, within a bounded number of attempts.

**Acceptance Scenarios**:

1. **Given** an item whose analysis fails every time, **When** the scan runs, **Then** the
   item is retried a bounded number of times, then skipped and counted in "not scanned",
   and every other item is analyzed.
2. **Given** an item whose analysis never finishes, **When** the scan runs, **Then** the
   wait for that item is cut off after a time limit, it counts as one failed attempt, and
   the scan continues.
3. **Given** an item that crashes the app on every attempt, **When** the user relaunches
   and resumes, **Then** each crash counts as one failed attempt for the piece in flight;
   after the limit the piece is split, and after the single item reaches the limit it is
   skipped. The user never has to resume more than a bounded number of times.

---

### User Story 3 - Temporary problems retry themselves (Priority: P3)

Analysis can fail for reasons that pass: the phone is briefly out of memory, the analysis
engine is not ready, the phone is too hot, the library is being changed. The scan should
wait and try the piece again with increasing delays instead of failing or marking items as
not checked.

**Why this priority**: Without it, retry limits meant for bad files would be consumed by
ordinary hiccups, and healthy items would be reported as not checked.

**Independent Test**: Make analysis fail for the first two attempts of every piece and
succeed on the third; confirm every item is analyzed, with waits between attempts, and
nothing is reported as not checked.

**Acceptance Scenarios**:

1. **Given** a piece fails for a temporary reason, **When** the scan continues, **Then** the
   piece is retried after a short delay, then a longer one, up to the attempt limit.
2. **Given** the delays, **When** the user pauses or stops, **Then** the wait ends at once
   and the piece stays pending with its attempt count saved.

---

### User Story 4 - The library changes between runs (Priority: P4)

Between an interruption and a resume, the user deletes photos or takes new ones. The resumed
scan must skip items that are gone and still cover the new ones, without starting over.

**Why this priority**: Resumes that happen hours later are the normal case for a background
scan.

**Independent Test**: Interrupt a scan, delete some not-yet-scanned items and add new ones,
resume, and confirm that deleted items are skipped silently, new items are analyzed before
the scan reports completion, and already-analyzed items are not redone.

**Acceptance Scenarios**:

1. **Given** items in a pending piece were deleted from the library, **When** the piece runs,
   **Then** those items are skipped and not counted as failures.
2. **Given** items were added to the library during an interruption, **When** the scan
   resumes, **Then** the new items are added as new pieces and analyzed before the scan is
   reported complete.

---

### Edge Cases

- **Kill between results and progress being saved**: results and the piece's state are saved
  together, so either both exist or neither; the piece is redone and the outcome is the
  same.
- **Attempt counting after a crash**: a piece that was in progress when the app died counts
  that run as one failed attempt, since the app cannot know why it died.
- **Retries exhausted everywhere** (for example analysis is unavailable on this device): the
  scan still finishes, reports how many items could not be checked, and does not loop.
- **Items that could not be checked**: kept with a reason and counted in the existing "not
  scanned" total; a later full scan tries them again, but only a bounded number of times
  across scans.
- **Pause, stop, background expiration** (002): the piece in flight is saved as soon as it
  is finished or checkpointed; the job stays resumable in all cases.
- **Photos access removed**: the scan pauses as if the system ended it; the Access screen
  from 001 explains what to do; pieces stay pending.
- **Delete all data**: the job and its pieces are removed with everything else.
- **Upgrading from an app version with an unfinished old-style scan**: the old progress is
  honoured; already-analyzed items are not redone; the remaining items become pieces.
- **Very small libraries**: a scan of fewer items than one piece behaves exactly as today.

## Requirements *(mandatory)*

### Functional Requirements

**Durable job**

- **FR-001**: A full scan MUST be saved as a job made of ordered pieces of work of at most a
  small fixed number of items (the plan sets the number, in the range 25 to 100), each with
  its own state (pending, running, done, failed, skipped) and attempt count.
- **FR-002**: The results of a piece and its "done" state MUST be saved together, so that a
  failure at any moment leaves the store either with both or with neither.
- **FR-003**: On resume, the scan MUST continue at the first unfinished piece and MUST
  re-analyze at most one piece's worth of items.
- **FR-004**: Resuming MUST NOT require comparing the whole library with stored results;
  for a library of 100,000 items, analysis restarts within 2 seconds of tapping Resume.

**Retry and isolation**

- **FR-005**: A piece that fails MUST be retried with increasing delays up to a fixed attempt
  limit (the plan sets the numbers, in the range 3 to 5 attempts, delays from about 1 second
  to under a minute). A piece in progress when the app died counts as one failed attempt.
- **FR-006**: A piece that reaches the attempt limit MUST be split into smaller pieces that
  are retried; a single item that reaches the limit MUST be marked "could not be checked"
  with a reason and skipped. The scan MUST continue in every case.
- **FR-007**: A single item's analysis MUST be cut off after a time limit (the plan sets it,
  about 10 to 30 seconds); the cut-off counts as one failed attempt for that item only.
- **FR-008**: Items marked "could not be checked" MUST be counted in the existing "not
  scanned" total, kept with their reason, and retried on later full scans no more than a
  bounded number of times.

**Progress and control**

- **FR-009**: Progress MUST be derived from saved piece state plus the items finished in the
  piece in flight and MUST drive the in-app and outside-app displays from 001 and 002
  unchanged. It MUST NOT decrease across a pause, stop, or system expiration; after an
  unexpected exit it MAY restart from the last saved piece, at most one piece lower.
- **FR-010**: Pause, stop, and background expiration (001 FR-005, 002 FR-006 to FR-010)
  MUST save the piece in flight as soon as it is finished or checkpointed and leave the job
  resumable. A retry delay in progress MUST end immediately on pause or stop.
- **FR-011**: Items deleted from the library before their piece runs MUST be skipped without
  counting as failures; items added during an interruption MUST become new pieces that run
  before the job is reported complete.

**Data and compatibility**

- **FR-012**: The last few jobs MUST be kept with their outcome (completed, stopped, how many
  items could not be checked) for the user to see in Settings, and MUST be removed by
  Delete All Data (001 FR-018).
- **FR-013**: Piece records MUST contain only item identifiers, states, counters, and failure
  reasons. No new data leaves the device (Constitution Principles I and II).
- **FR-014**: Existing stored results MUST remain valid after the update; an unfinished
  old-style scan MUST resume without redoing analyzed items.
- **FR-015**: The job model MUST allow other kinds of pieces later (for example matching
  phases) without changing how durability, retry, and progress work.

### Key Entities

- **Scan Job**: one user-started scan: when it started, its kind, its state (running, paused,
  stopped, completed), its pieces, and its outcome summary.
- **Piece** (work unit): an ordered list of item identifiers, a state (pending, running,
  done, failed, skipped), an attempt count, the last failure reason, and timestamps.
- **Not-Checked Item**: an item set aside after repeated failure, with its reason and the
  number of scans that have tried it.
- **Scan Session** (from 001): becomes the job's summary view for the existing screens.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100 runs that kill the app at a random moment during a 2,000-item scan,
  every run completes after Resume, and the number of items re-analyzed after each kill
  never exceeds one piece.
- **SC-002**: Resuming a scan of a 100,000-item library restarts analysis within 2 seconds.
- **SC-003**: A 1,000-item library with one item that always fails, one that always hangs,
  and one that always crashes the app completes with exactly those three reported as not
  checked, after at most the bounded number of attempts set in the plan.
- **SC-004**: After any kill, stored results and saved piece states agree in 100% of
  checks (no piece marked done without its results, no results without the piece recorded).
- **SC-005**: The progress count never decreases across a resume after a pause, stop, or
  system expiration in 100% of runs; after an unexpected exit it is at most one piece (32
  items) lower than before.
- **SC-006**: With analysis failing for the first two attempts of every piece, 100% of
  items are analyzed and 0 are reported as not checked.

## Assumptions

- "Task" in the request means the library scan. Removal is not a long-running task and is
  unchanged (001 FR-012, FR-013).
- A piece is the unit of durability; within a piece, items may still be processed
  concurrently as today. Losing up to one piece of work on a crash is acceptable.
- The attempt limit, delays, piece size, and per-item time limit are fixed by the plan and
  may be tuned later from measurements; they are not user settings.
- "Could not be checked" items appear in the existing "not scanned" count; a separate list
  with reasons is a later addition if users ask for it.
- Since 2026-10-18 the free app does not analyze videos (video analysis is a one-time $2
  Pro feature, not built yet; see specs/004-phased-cleaning/spec.md FR-004a; since 2026-10-24
  there is no Pro version, specs/016-free-photos-only/spec.md), so "every item is analyzed" above means every photo. A video is marked "metadata
  only", which is not "not scanned", is not counted there and is not retried.
- The quick check on app open (001 FR-005a) uses the same pieces when it has more than one
  piece of work; for a handful of new photos it behaves as today.
- Everything from 001 and 002 about privacy, confirmation, and background continuation
  applies unchanged.
