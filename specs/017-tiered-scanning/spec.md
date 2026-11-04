# Feature Specification: Tiered Scanning

**Feature Branch**: `017-tiered-scanning`

**Created**: 2026-11-04

**Status**: Draft (engine and tests written; the SwiftUI side is written but has not been built or run, see
Validation)

**Input**: User description: "Now let's do tiered scanning. Instead of doing all types of cleanup work in a
single scan, do a tiered scan where the things that are easy and fast to do are done and presented for
cleanup first. Along with that, we can reimagine the UI too."

**Builds on**: [004-phased-cleaning](../004-phased-cleaning/spec.md) (this entry finishes its steps, its
"Stop after this step" and the idea that a category never claims "clean" while a step that feeds it is
unfinished), [008-staged-cleanup-at-scale](../008-staged-cleanup-at-scale/spec.md) (quick wins, newest-first
blocks, results while the scan runs), [010-defer-vision-work](../010-defer-vision-work/spec.md) (the per-photo
record of Vision work left out, and the rule that analyzes a photo again when a detector comes to need it),
[011-result-levels](../011-result-levels/spec.md) (Unimportant reads the face pass of soft photos) and
[015-more-photo-clutter](../015-more-photo-clutter/spec.md) (Bursts is a category that needs only metadata).
Everything this entry does not mention is unchanged. Where it disagrees with 004, this one wins for the
parts of 004 that were never built.

## Why

Today one scan gives every photo every signal in one pass. A photo's duplicate hash, its sharpness, its
Vision feature print and its face score all come out of the same preview, so a category can be listed only
once the photos that feed it have gone through all of that. 008 softened this with newest-first blocks and a
"quick wins" step for screenshots and videos, but the middle of the scan is still one long bar, and nothing
the person could clean in seconds waits for nothing: bursts, which the library describes without opening a
photo (015), are listed only after their frames have been through Vision.

The costs differ a lot by kind of work, and the code already knows it. `CategoryDetector.needsAnalysis`
separates the categories that need only metadata (Bursts, Screenshots, Screen Recordings, Large Videos) from
the ones that read the analysis. Inside the analysis, 008 measured on the Mac that Vision's two requests are
about half of a photo's cost (6.4 of 13 ms), and 009 that the Neural Engine, not the cores, is the ceiling.
010 already records, per stored photo, which Vision work was left out and re-analyzes a photo when the
library comes to demand it. A tier is that idea applied on purpose, to the whole library, in order of cost.

## The tiers

A tier is named for the cheapest thing it has to read. Tiers run in order. A tier's results can be reviewed
and removed as soon as it is done, and the next tier starts by itself unless the device or the person says
otherwise.

| Tier | Reads | Completes | Cost per photo |
|------|-------|-----------|----------------|
| **Quick wins** (`instant`) | Library information only; no photo is opened | Screenshots, Screen Recordings, Large Videos, Bursts (and Live Photos when 015 Story 2 lands) | microseconds; one listing of the library |
| **Photo check** (`photos`) | One 512 px preview and cheap arithmetic on it: hash, miniature, sharpness, (emptiness) | Duplicates, Blurry (and Dark when 015 Story 4 lands) | the preview fetch dominates |
| **Deep check** (`deep`) | Vision on the same preview: feature print, face quality | Similar Shots, Unimportant, and better keepers in Bursts | Neural Engine bound |

`CleanupCategory.tier` is the one place this table lives in code.

Only the last row is optional in spirit. A person who stops after the photo check has still cleaned the
duplicates, blurry photos, screenshots and bursts, which is most of the space.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Quick wins include bursts, in seconds (Priority: P1)

A person with 30,000 photos taps Scan. Within seconds Home lists their screenshots, screen recordings, large
videos and bursts. They can open any of them and clean while nothing has been analyzed yet.

**Why this priority**: Bursts are the largest pure waste the earlier tiers could not show early, and the
group is known from the library alone.

**Independent Test**: Scan a library of 12-frame bursts with an analyzer that never finishes. Assert that
Bursts is listed, with the keeper the library names (picked, favourite, or the frame Photos shows), before
any preview is requested, and that the frames are analyzed afterwards like any photo.

**Acceptance Scenarios**:

1. **Given** a scan has just started, **When** the plan is made, **Then** every frame of a burst with two
   or more frames that is not yet stored is stored from its metadata, and the first progress event carries a
   new `publishedRevision`.
2. **Given** such a frame is stored from metadata and the scan is stopped before it is analyzed, **When** the
   next scan plans, **Then** the frame is analyzed (a stored item that came from metadata alone is complete
   only if its kind needs no analysis).
3. **Given** a burst frame that Duplicates later claims, **When** the photo check finishes, **Then** it
   leaves Bursts and appears in Duplicates (first matching category wins, 001 FR-007); the person's open
   list does not change under them (004 FR-010).

---

### User Story 2 - The photo check finishes before Vision starts (Priority: P1)

The person watches the scan. Quick wins are ready. The photo check runs over the library, newest first, and
publishes duplicates and blurry photos in blocks. When it ends, those two categories are final. The scan
then moves on to the deep check.

**Why this priority**: This is the headline. The whole library's cheap categories are complete in roughly
the time half the work takes, and nothing about them depends on the Neural Engine.

**Independent Test**: Scan a library with an analyzer that records what it is asked for. Assert that during
the photo check no photo is asked for a feature print or a face score, that Duplicates and Blurry equal
those of a one-shot scan when it ends, and that Similar is empty and not claimed to be clean.

**Acceptance Scenarios**:

1. **Given** the photo check is running, **When** an analyzer is called, **Then** the request names no
   Vision work and forbids the analyzer from adding any (`VisionWork.exact`), and the stored item records
   all of it as skipped.
2. **Given** the photo check ended, **When** results are built, **Then** Duplicates and Blurry are equal to
   those a one-shot scan finds, Similar and Unimportant list nothing (010 FR-008 and 011 FR-005 already
   refuse to group on a skipped print or a skipped face pass), and the screen says the deep check has not
   run.
3. **Given** the person pauses, stops or the app is killed during the photo check, **When** they come back,
   **Then** Resume continues the job as in 003, and a stopped scan offers to continue (Story 3).

---

### User Story 3 - The deep check follows, waits, or is asked for (Priority: P2)

When the photo check ends, the deep check starts by itself. If the phone is in Low Power Mode it does not;
Home says why and offers "Run Now". If the person stopped the scan, or closed the app between the two, Home
offers "Look Deeper" and says how many photos it would compare.

**Why this priority**: It gives the person control over the expensive part without a first-run question, and
finishes 004's "Stop after this step" and "Continue finding more" in the shape the app has.

**Independent Test**: Run a tiered scan with a wait reason injected; assert the photo check completes, the
deep job is not planned, the progress says what is owed and why it waits, and `startDeepScan()` runs exactly
the owed photos and nothing else.

**Acceptance Scenarios**:

1. **Given** the photo check ended and the device may run it, **When** the deep check is planned, **Then** a
   second job starts in the same run, so the stream, the pause and stop controls and the continued
   processing task carry on without a gap.
2. **Given** Low Power Mode is on, **When** the photo check ends, **Then** no deep job is planned, the final
   progress carries `deepRemaining` and `deepWait == .lowPowerMode`, and the run ends `completed`.
3. **Given** a library with owed deep work, **When** the person taps Run Now or Look Deeper, **Then** only
   the photos whose Vision work is owed are analyzed again, and a photo whose Vision work is not wanted is
   not.
4. **Given** the app is killed after the photo check job ended and before the deep job was stored, **When**
   it is opened, **Then** the library reads as "photo check done, deep check owed": the same state as a
   deferral, with nothing to recover.
5. **Given** the app is killed during the deep job, **When** it is opened, **Then** Resume continues that
   job (003).

---

### User Story 4 - Home shows what is ready, what is running, what waits (Priority: P2)

While a scan runs, Home no longer shows one bar. It shows three rows, one per tier, each in one of: ready,
running with its own count, waiting, waiting for a stated reason, not run. Under them the categories are
grouped by the tier that produced them, so "Ready now" is a short list the person can act on at once, and
the later groups say what they are still looking for. When the scan is over and nothing is owed, Home is the
flat list of earlier specs.

**Why this priority**: The engine is only as good as the person's sense of it. A single bar hides that
Screenshots has been ready for ten minutes.

**Independent Test**: UI test on the demo library with a slow analyzer: the three tier rows exist, the first
is ready before any photo is checked, the second shows a count, the third says it waits; after the scan the
flat list returns and every identifier of earlier specs still resolves.

**Acceptance Scenarios**: see Requirements FR-012 to FR-016.

---

### User Story 5 - Nothing is different at the end (Priority: P1)

When every tier has run, the library is in the state a one-shot scan of it leaves, and the results are
equal.

**Independent Test**: The staged-scan equality test of 010 (`aLibraryScannedInTwoStagesFindsWhatAOneShotScanFinds`)
run again with the tiered pipeline against a one-shot scan and a complete scan: equal categories, keepers,
selection, not-scanned count, and the same stored analysis for what a detector reads.

## Edge Cases

- A photo whose only demand is a soft, lonely, unprotected shot (the Unimportant candidate of 011): its
  demand is known only once its sharpness is, so the deep plan reads the stored sharpness and wants its face
  pass then. The photo check never runs that pass.
- A photo added between the two jobs is analyzed by the deep job like a new photo of a quick check: with the
  Vision work its neighbours demand.
- A photo with no preview (only in iCloud) is `notScanned` after the photo check, is not owed deep work
  (nothing was analyzed), and is retried by a later full scan exactly as in 003 FR-008.
- A library with nothing owed: the deep check is not planned and the run ends after the photo check.
- A quick check on opening the app never starts the deep backlog by itself (001 FR-005a). It analyzes new and
  changed photos with the work their neighbourhood demands, and re-analyzes a stored photo that skipped
  Vision only if something that changed is within the similar-shots window of it, or it changed itself.
- Stop during the deep check: the photos it finished keep their Vision results, the rest are still owed, and
  Home offers Look Deeper.
- The store was written by an earlier build: it opens unchanged. A photo stored before this entry with a skip
  record reads as before. A session with no tier reads as a one-pass job and is finished as one.
- Limited access, Mac, iPad: unchanged. The Mac never defers the deep check (it has no Low Power Mode) and its
  layout is not changed by this entry.

## Requirements *(mandatory)*

### Functional Requirements

**The model**

- **FR-001**: `ScanTier` (`instant < photos < deep`) and `CleanupCategory.tier` MUST exist in the package and
  be the only definition of which tier completes a category.
- **FR-002**: The package scan MUST keep its earlier behaviour unless asked: `ScanPipeline(tiered:)` defaults
  to false. The app turns it on.

**Quick wins**

- **FR-003**: In a tiered full scan the plan MUST store, from metadata and with `AnalysisSource.metadataOnly`,
  every not-yet-stored still image that belongs to a burst of two or more frames in the library, and report
  it through `publishedRevision`. They stay in the job.
- **FR-004**: A stored `metadataOnly` item whose kind needs analysis MUST be planned for analysis. (Videos
  and screenshots are complete as `metadataOnly`; a burst frame stored early is not.)

**Photo check**

- **FR-005**: The photo check MUST analyze every new or changed photo with no Vision work, and MUST tell the
  analyzer to add none (`VisionWork.exact`), including the face pass `DefaultAnalyzer` adds for an
  Unimportant candidate.
- **FR-006**: A photo analyzed by the photo check MUST be stored with all Vision work recorded as skipped
  (010), so that no detector reads a missing print or face score as a negative.

**Deep check**

- **FR-007**: The owed Vision work of a stored, analyzed photo MUST be `VisionDemand.work(for:)` of the
  current library, plus the face pass if the photo is an Unimportant candidate by its stored sharpness
  (`UnimportantDetector.isCandidate`). A photo is owed work when its recorded skipped work intersects it.
  `StoredItemSummary` MUST carry the sharpness for this.
- **FR-008**: The deep job MUST analyze exactly the owed photos (and any new or changed photo, as a quick
  check does), asking each for exactly what is owed, in chunks like any job (003).

**Sequencing and control**

- **FR-009**: In a tiered full scan the photo check and the deep check MUST be two durable jobs
  (`ScanSession.tier`, optional and additive) run by one `run`: the photo job ends `completed` and its
  chunks are removed, then the deep job is created, with no terminal event between them. Nothing needs
  recovery if the app dies between the two writes.
- **FR-010**: The deep job MUST NOT be planned while `deepWait` names a reason (Low Power Mode in this
  entry). A full scan that ends without planning it MUST report `deepRemaining` and `deepWait`.
  `Scanner.startDeepScan()` MUST run the deep job whatever `deepWait` says.
- **FR-011**: A quick check MUST NOT analyze owed deep work that is not near a change (above).

**Progress**

- **FR-012**: `ScanProgress` MUST carry `tier` (nil for a one-pass job), `deepRemaining` and `deepWait`,
  all defaulted so earlier call sites compile. `processed` and `total` are those of the running job.
- **FR-013**: `ScanTierStatus` (package, pure) MUST turn a progress value, and whether a scan is running,
  into one state per tier: `ready`, `running(done, of)`, `waiting`, `waitingFor(reason)`, `notRun(owed)`. The
  screens read nothing else to describe the tiers.

**Screens**

- **FR-014**: While a tiered scan runs, or while deep work is owed, Home MUST show the three tiers with their
  states (FR-013) and group the category rows by tier, each group headed by its tier's state in plain
  words. Otherwise it MUST show the flat list of 014.
- **FR-015**: Home MUST NOT say "Nothing to clean up" or "looks clean" while deep work is owed; it MUST say
  what was not looked at and offer Look Deeper (004 FR-013).
- **FR-016**: Every accessibility identifier of earlier specs MUST still resolve. VoiceOver, Dynamic Type,
  Reduce Motion and the quiet tone of 012 apply to every new row. Counts are real counts; there are no time
  estimates (DESIGN §9.6), since none has been measured on a phone.

**Data and results**

- **FR-017**: After every tier has run, results MUST equal those of a one-shot scan of the same library
  (010 FR-009 and the equality test), apart from decisions the person made.
- **FR-018**: No new data is stored beyond one optional integer on the session record. Delete All Data
  removes it with the rest (001 FR-018).

## Decisions for you

Each has a default this entry follows unless you say otherwise.

1. **Where the tier boundaries are.** By what a category has to read: metadata, a preview, Vision. Default:
   yes. The alternative, tiers by how safe a removal is (Tier 0 to 3 of DESIGN §9.1), answers a different
   question and is already how the card text is written.
2. **The deep check starts by itself.** Default: yes, unless Low Power Mode is on. Not asking at first run
   keeps one button; stopping the scan is the way to decline, and Look Deeper the way back.
3. **Bursts are quick wins.** Default: yes. A burst can shrink when Duplicates claims one of its frames after
   the photo check, and its keeper can change when a sharper frame or a face score is known; neither moves
   under an open list (004 FR-010), and only a keeper the person chose is pinned (008 Decision 1).
4. **Tier groups only while it matters.** Default: grouped while a scan runs or deep work is owed, flat
   afterwards. A permanent grouping would turn a finished library into three headings for the sake of the
   scan that made it.
5. **No time estimates.** Default: counts only. Add ranges once the phone is measured (004 FR-021).
6. **Battery.** Default: not built. 004 FR-019 (below 20% and unplugged) needs the battery level, which
   UIKit gives only on the main actor; the injected `deepWait` closure is where it would go.
7. **The Mac layout.** Default: the engine runs tiered on the Mac; the sidebar and Overview are not
   redesigned here.

## Not done

- A phone measurement. Everything about speed here is a design claim until `ScaleBench` has a tiered mode and
  a phone has run it. The Mac figures quoted above are 008's and 009's.
- Live Photos and Dark (015 Stories 2 and 4): `CleanupCategory.tier` places them, nothing else here builds
  them.
- Time estimates, the battery rule, a user setting for "never run the deep check by itself".

## Success Criteria

- **SC-001**: In a tiered full scan, Bursts, Screenshots, Screen Recordings and Large Videos are listed before
  the first preview is requested.
- **SC-002**: At the end of the photo check, no analyzer call carried Vision work, and Duplicates and Blurry
  equal a one-shot scan's.
- **SC-003**: After both jobs, the staged-scan equality test passes against both a one-shot and a complete
  scan.
- **SC-004**: With the default `tiered: false`, every earlier test passes unchanged.
- **SC-005**: A kill at a random point of either job, or between them, ends with every photo analyzed and at
  most one chunk repeated (003 SC-001 holds in both jobs).

## Data & Network

The scan reads library metadata and the preview it already reads. It stores one optional integer (the tier) on
the session record and uses the existing skip record of 010. Everything stays in the local store; nothing is
sent anywhere, no network API is added, and the no-network checks are unchanged (constitution I, II, V).

## Validation

Package: `TieredScanTests` (planner scopes, the photo and deep jobs, deferral, resume across tiers, equality
with a one-shot scan), run by CI with the rest of the package.

The SwiftUI side (`iclean/`) is not compiled by CI and could not be built where this entry was written (a
Linux container with no Swift toolchain). It is written to mirror the existing views and is unbuilt and
unrun; the first thing to do on a Mac is `xcodegen generate` and a build. Nothing in the package depends on it.
