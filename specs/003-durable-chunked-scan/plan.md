# Implementation Plan: Durable Chunked Scan

**Branch**: `003-durable-chunked-scan` | **Date**: 2026-10-17 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/003-durable-chunked-scan/spec.md`

## Summary

A scan becomes a saved job of chunks of 32 items. Each chunk is leased (written as
running with this process's identity), run with the existing 4-wide analysis, and then
checkpointed: its results, its finished-bits, and the session counters are saved in one
transaction. On the next launch, a chunk still marked running belonged to a process that
died: it is re-run one item at a time with a save after every item, and an item the app
died on twice is set aside as "could not be checked". Failed items are retried with
increasing delays up to three runs per chunk, each item is cut off after 20 seconds, and
pause, stop, and background expiration release the chunk before waiting so a kill at
that moment is not mistaken for a crash. Resume reads the job's chunks instead of
comparing the whole library; a catch-up pass after an interruption picks up items added
meanwhile. The design was chosen from three independent proposals judged on robustness,
fit, testability, performance and extensibility (see [research.md](research.md)).

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), Xcode 27 / iOS 27 SDK

**Primary Dependencies**: unchanged (SwiftData, PhotoKit). No new frameworks.

**Storage**: one new SwiftData entity `ScanChunkRecord` (identifiers, state, counters);
optional columns added to `ScanSessionRecord` and `LibraryItemRecord`. Additive only, so
SwiftData's lightweight migration applies (research R6).

**Testing**: Swift Testing in `CleanupKit` (`DurableScanTests`: crash simulation by
seeding a chunk leased to a foreign process, reclaim rules, retries, timeouts, poison,
catch-up, store round trips); the existing XCUITest `testInterruptedScanResumesAfterRelaunch`
(kill, relaunch, resume); on-device kill-and-resume with the demo library.

**Target Platform**: iOS 18.0+ iPhone only (unchanged)

**Project Type**: mobile-app (single iOS app + one local Swift package), unchanged

**Performance Goals**: unchanged 001 targets; resume of a 100,000-item job reads one
session row and about 3,000 chunk rows, no item blobs, no library enumeration (FR-004).
One extra store write per chunk (the lease) at about 1.6 s of work per chunk.

**Constraints**: a kill loses at most one chunk (32 items, 1 in isolate mode); per-item
time limit 20 s; 3 attempts per chunk with 2 s and 8 s delays; 5 crashes end a job; an
item is retried on at most 6 later full scans.

**Scale/Scope**: 5 new files, 8 touched files in `CleanupKit`; 3 touched in the app.

## Constitution Check

| Principle | Gate | Pre-research | Post-design |
|-----------|------|:------------:|:-----------:|
| I. Local-Only Data | Chunk records hold identifiers and counters only; nothing new leaves the device | ✅ | ✅ FR-013 |
| II. No Outbound Network | No networking code; `check-no-network.sh` unchanged | ✅ | ✅ |
| III. Offline-Safe Dependencies | No dependency added | ✅ | ✅ |
| IV. User Owns Their Data | Delete All Data removes jobs and chunks; Settings lists recent scans | ✅ | ✅ FR-012 |
| V. Verifiable Privacy | Static check unchanged | ✅ | ✅ |
| Data Handling Constraints | Same store, same protection, same backup exclusion | ✅ | ✅ |
| Workflow gate | Data & Network statement below | ✅ | ✅ |

**Result**: PASS.

### Data & Network statement

- **Data touched**: the same previews and metadata as 001. New stored data: per chunk,
  up to 64 asset identifiers, a state, a 64-bit done mask, attempt and crash counters, an
  optional retry time, an optional process identifier, and an optional short error word.
  Per item, an optional failure reason and an attempt count. Per session, four counters.
- **Where stored**: the existing SwiftData store (Application Support, excluded from
  backup). Chunks are deleted when their job ends.
- **Network**: none.

## Project Structure

### Documentation (this feature)

```text
specs/003-durable-chunked-scan/
├── plan.md, research.md, data-model.md, quickstart.md, tasks.md
└── contracts/services.md, contracts/ui.md
```

### Source Code (repository root)

```text
Packages/CleanupKit/Sources/CleanupKit/
├── Models/Types.swift            # ScanFailure; LibraryItem.scanFailure/scanAttempts; ScanSession counters; ScanProgress.failed
├── Models/ScanChunk.swift        # NEW: ScanChunk, ScanChunkState, ScanRetryPolicy
├── Scanning/ScanPipeline.swift   # chunk-driven run loop (lease, run, checkpoint, retry, reclaim, catch-up)
├── Scanning/ScanPlanner.swift    # NEW: pure diff + chunking
├── Scanning/ScanReclaim.swift    # NEW: pure crash-recovery rules
├── Scanning/Timeout.swift        # NEW: per-item time limit that never awaits a hung task
├── Store/ScanChunkRecord.swift   # NEW: SwiftData entity
├── Store/Store.swift, SwiftDataStore.swift   # createJob, chunks, saveChunks, checkpoint, deleteChunks, sessions, scanAttempts
├── Store/ScanSessionRecord.swift, LibraryItemRecord.swift   # optional columns
└── Library/PhotoLibrary.swift, PhotoKitLibrary.swift        # fetchItems(withIDs:)

iclean/Features/Scanning/ScanningView.swift   # "N couldn't be checked"
iclean/Features/Settings/SettingsView.swift   # Recent scans
iclean/App/AppModel.swift, DemoPhotoLibrary.swift
Packages/CleanupKit/Tests/CleanupKitTests/Unit/DurableScanTests.swift   # NEW
Packages/CleanupKit/Tests/CleanupKitTests/Fakes/FakePhotoLibrary.swift  # hangIDs, FlakyAnalyzer, fetchItems
```

**Structure Decision**: same layout as 001 and 002. The three pure pieces (planner,
reclaim, policy) are separate files so the rules are tested without a store or a
library; the pipeline actor owns all state transitions.

## Risks & open items

- **Lightweight migration** of the three shipped entities is additive and optional-only.
  `StoreMigrationTests` opens a store file written by the previous schema
  (`Fixtures/previous-store`) with the current one and checks that items, keep marks and
  the unfinished session survive and that an old-style scan continues from its count. The
  first launch of the new build over the real store on the user's phone has not been
  observed (the phone was locked).
- **Pause window**: a kill between `pause()` saving the session and the chunk's release
  checkpoint (tens of milliseconds) counts as one crash. Harmless: the next run uses
  isolate mode for that chunk once.
- **Hung requests leak** until PhotoKit or Vision returns; the per-item timeout keeps the
  scan moving but does not cancel the underlying request. Follow-up: cancel the PhotoKit
  image request on task cancellation.
- **Stop deletes the job's chunks**; a later scan plans the remainder from the store
  diff, as before. Resume-without-diff applies to pause, crash, and background expiration.

## Complexity Tracking

No constitution violations to justify.
