# Data Model: Durable Chunked Scan

Delta to [001 data-model.md](../001-photo-cleanup/data-model.md) and
[002 data-model.md](../002-background-scan-progress/data-model.md).

## ScanChunk (stored as `ScanChunkRecord`)

| Field | Type | Notes |
|-------|------|-------|
| `jobID` | UUID | The session this chunk belongs to |
| `sequence` | Int | Order within the job; `key = "<jobID>/<sequence>"` is unique |
| `assetIDs` | [String] | ≤ 64 identifiers (FR-013: ids only) |
| `state` | `pending` / `running` / `done` | |
| `doneMask` | UInt64 | Bit `i` set when `assetIDs[i]` is finished (analyzed, skipped, or given up) |
| `attempts` | Int | Failed runs; give up on failing items at `maxAttempts` (3) |
| `crashes` | Int | Deaths while running |
| `isolate` | Bool | After a death: one item at a time, saved after every item |
| `suspectIndex` | Int? | Item in flight at the last death (isolate mode) |
| `notBefore` | Date? | Earliest retry time |
| `owner` | UUID? | Process incarnation holding the lease; nil unless running |
| `lastError` | String? | `transient` / `timeout` |

**State machine**

```text
pending ──lease (owner = me)──▶ running ──all bits set──▶ done
   ▲                              │
   ├── release before waiting ────┤  (pause, stop, heat, expiration: bits kept, owner nil, no attempt)
   ├── failed run, attempts < 3 ──┤  (owner nil, notBefore = now + 2 s / 8 s)
   │                              └── failed run, attempts = 3 ──▶ done (failing items set aside)
   └── reclaim at launch (owner ≠ me) ──┘  (crashes += 1; isolate → suspect → poison)
```

Invariants: at most one chunk is `running` per live process; a `done` chunk's items are
all in the store or set aside; chunks are deleted when the job ends.

## ScanSession (stored, extended)

| New field | Type | Notes |
|-----------|------|-------|
| `baseProcessed` | Int | Items counted before chunks existed (adopted sessions) |
| `failedItems` | Int | Items set aside (`scanFailure` ≠ nil) |
| `crashCount` | Int | Deaths during this job; 5 ends the job as `stopped` |
| `interruptedCount` | Int | Launches that found a leased chunk; triggers one catch-up |

`processedItems` = `baseProcessed` + finished items in chunks. The saved value only ever
matches saved results (`pause()` writes the last checkpointed counters), so after an
unexpected exit it can be at most one chunk below what the user last saw.

## LibraryItem (stored, extended)

| New field | Type | Notes |
|-----------|------|-------|
| `scanFailure` | `transient` / `timeout` / `crashed`, optional | Only with `analysisSource == .notScanned` |
| `scanAttempts` | Int | Scans that ended with the item unanalyzed; retried while < 6 |

## ScanProgress (in memory, extended)

| New field | Type | Notes |
|-----------|------|-------|
| `failed` | Int | Subset of `notScanned` that was given up on |

## ScanRetryPolicy (in memory)

`chunkSize 32`, `maxAttempts 3`, `backoff [2 s, 8 s]`, `itemTimeout 20 s`,
`crashBudget 5`, `crossScanAttempts 6`.
