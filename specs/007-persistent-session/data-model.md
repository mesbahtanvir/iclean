# Data Model: Persistent Review Session

Delta to [001 data-model.md](../001-photo-cleanup/data-model.md), [003 data-model.md](../003-durable-chunked-scan/data-model.md)
and [004 data-model.md](../004-phased-cleaning/data-model.md) (whose results snapshot, store revision
and seen-groups details this replaces). Two new entities are added to the existing store and nothing
existing is changed, so SwiftData's lightweight migration opens an old store unchanged (003 R6,
[research R12](research.md)). Nothing here holds photo content: only identifiers, counts, choices, a
breadcrumb, and a derived copy of metadata the store already holds.

## StoreMetaRecord (new, one row)

| Field | Type | Notes |
|-------|------|-------|
| `key` | String, unique | always `"meta"` |
| `resultsRevision` | Int64 | starts at 0; only goes up; never reset, not even by Delete All Data (which moves it on), so a number is never reused and an old snapshot can never match again |
| `formatVersion` | Int | 1. A build that finds a number it does not know treats every state row as absent |
| `createdByBuild` | String? | informational |

The counter moves **inside the same transaction as the write that changes the results inputs**, never
before or after it.

## StateRecord (new, one row per key)

| Field | Type | Notes |
|-------|------|-------|
| `key` | String, unique | `results`, `decisions` or `position` (`StateKey`). New kinds later are new keys, not new tables |
| `version` | Int | the payload format version of that key. An unknown version is treated as absent |
| `payload` | Data | LZFSE-compressed JSON, stored inline (no external storage, no side file) |
| `checksum` | Data | SHA-256 of the stored payload bytes. A mismatch on read means the row is deleted and treated as absent |
| `basedOnRevision` | Int64 | the store revision the payload was built for. Only meaningful for `results`; 0 for the others |
| `updatedAt` | Date | |

A problem with a payload never throws to the caller: a bad checksum, an unknown version or a payload
that does not decode deletes the row and returns nothing. What "nothing" means depends on the key:
`results` gives a rebuild, `decisions` gives the suggested ticks, `position` gives Home. A failure of the
store itself (a read that throws) is different: it is a load failure, never "nothing".

## Payloads

### `results` (`ResultsSnapshot`, format 1)

Header:

| Field | Type | Notes |
|-------|------|-------|
| `formatVersion` | Int | 1 |
| `builderKey` | struct | what the copy was built for (below) |
| `builtAt` | Date | the 7-day age limit counts from here |
| `itemCount` | Int | `LibraryItemRecord` count when built; must equal the store's |
| `keepMarkCount` | Int | `KeepMarkRecord` count when built; must equal the store's |

`builderKey`:

| Field | Notes |
|-------|-------|
| `builderVersion` | `BuilderVersion.current`, a constant a person raises when detectors, thresholds, `KeeperRules` or `DateCredibility` change. A golden-output test over the baseline library fails if output changes without a raise |
| `detectors` | the categories enabled (the detector set) |
| `videoAnalysis` | the Pro flag (`ProFeatures`) |
| `access` | library access level (`full` or `limited`) |
| `timeZone`, `calendar` | identifiers; midnight and placeholder checks and shared-timestamp counts depend on them (006) |
| `thresholds` (optional) | a string of the threshold constants the detectors, keeper rules and date rules read, so editing one invalidates by itself |

Body:

| Field | Notes |
|-------|-------|
| `categories` | non-empty categories in `CleanupCategory` order, each with its groups |
| group | `type`, `members` (asset ids in display order), `keepers` (asset ids), `confidence`, `dateNotes` (asset id to reasons, 006). The group's own id is **not** stored; it is a hash of type and sorted members and is recomputed |
| `notScannedCount` | Int |
| `items` | one slim item **per group member only** (below) |
| `defaultSelection` | not authoritative. The applier recomputes the default from the groups on every publish; a stored copy, if kept, is never trusted |

A slim item holds: asset id, kind, capture date, modification date, pixel size, duration, favorite,
has-adjustments, portrait, long-exposure, burst id, album names, added date, has-location, analysis
source, sharpness, aesthetics score, face quality, byte size, and the size-estimated flag. It holds **no**
thumbprint, feature print or hash, and no `analyzedAt`, `scanAttempts` or `scanFailure`.

Built results and restored results have the same shape (`CleanupResults.slimmed()`), so the rest of the
app cannot tell them apart. Size at 30,000 photos: a target of under 3 MB (estimate, to be measured in
Release). Asset ids and album names may be interned if it is larger.

The snapshot gate, in order: row present; `version` known; `basedOnRevision` equals the store revision;
checksum verified at read; payload decodes; header format known; `builderKey` equals the current key;
`itemCount` and `keepMarkCount` equal the store's counts; `builtAt` is at most 7 days ago. Any failure
deletes the row silently and the cold path rebuilds.

### `decisions` (`ReviewIntent`, format 1)

| Field | Type | Meaning |
|-------|------|---------|
| `forcedOn` | {asset id: decidedAt} | photos the person ticked although the suggestion was to keep them |
| `forcedOff` | {asset id: decidedAt} | photos the person unticked although the suggestion was to remove them |
| `keeperChoices` | {asset id: decidedAt} | photos the person chose with "Keep This One" |
| `removableTicks` | set of asset ids | photos in `forcedOn` that were ticked while they were an ordinary removable copy; if a rebuild later makes one the kept copy, the tick is not replayed (the person never chose to remove the copy now suggested to be kept). A tick made on a keeper on purpose is not in this set and stays. |
| `seenGroups` | optional | reserved for spec 004; not written by this feature |

Rules for recording (the reducer, after every change, never by diffing the selection set):

- Tick or untick of a photo: set the matching map, clear the opposite one for that photo.
- "Keep This One" on a photo: add a keeper choice and clear its `forcedOn`. The keeper choice itself
  keeps the photo out of the selection (the applier makes it a keeper before the defaults are
  recomputed), so no `forcedOff` is set; an older choice for another photo of the same group stays
  until it expires, and replaying choices oldest first makes the latest one win.
- Normalization: an override equal to the current default is pruned (the default depends on the groups,
  so this runs against the current results).
- Removed photos, and photos confirmed gone from the library, are forgotten.
- Expiry on read: `forcedOn` after 7 days; `forcedOff` and keeper choices after 180 days.

Rules for replay (the applier, on every publish: launch, foreground, scan publish, rebuild, and every
in-place `removing()` call):

1. Keeper choices in `decidedAt` order (oldest first, so the newest wins). A choice applies to the group
   that currently contains the photo; favorites and Always keep photos stay keepers too. A choice is
   dropped if the photo is gone or its group has no keepers (a single-photo category).
2. The default selection is recomputed from the groups (removable members of categories that preselect,
   minus favorites and Always keep photos).
3. Selection = (defaults + valid `forcedOn`) minus `forcedOff`.

| Case | Result |
|------|--------|
| `forcedOn`, photo still a removable member, not a favorite, not keep-marked, not modified after `decidedAt`, under 7 days | selected |
| `forcedOn`, photo not a member, or now a favorite or keeper, or modified after `decidedAt`, or older than 7 days | dropped |
| `forcedOff`, any photo | not selected (always honored) until 180 days or removal |
| keeper choice, photo in a group with keepers | that photo is a keeper of its group |
| keeper choice, photo gone or in a group with no keepers | dropped |
| group id changed because a member left | no effect: nothing is keyed by group id |

Write size: one row. Select All on 20,000 photos is about 1 to 2 MB before compression (estimate).

### `position` (`ReviewPosition` with `Route`, format 1)

| Field | Type | Meaning |
|-------|------|---------|
| `path` | [Route] | `category(c)` or `group(c, anchors)`: the group is identified by up to 3 of its photos, found again as "the group in category c that contains any anchor" |
| `focusAssetID` | String? | the photo last touched, scrolled to on restore |
| `savedAt` | Date | the 24-hour window counts from here |
| `restoreAttempts` | Int | restores begun and not yet proven to have survived (below) |

Never stored: a sheet, the photo viewer, the confirm dialog, Settings, scan progress, scroll offsets.
Not the type-erased `NavigationPath`: a route this build cannot decode drops the whole position and
nothing else.

Restore rules: a position is restored on its own only if `path` is not empty, `savedAt` is at most 24
hours ago, and `restoreAttempts` is under 2. Before restoring, the counter is written (+1, awaited).
It is reset to 0 by a clean flush at `.inactive` or `.background`, or after 30 s in the foreground. If
the app dies first it stays counted, and at 2 the next launch shows the Continue row instead. The route
is validated prefix by prefix against the published results and shortened to the nearest valid
ancestor. Going to Home on purpose writes an empty path.

## Store changes (interface, in prose)

| Method | Reads or writes | Moves the revision? |
|--------|-----------------|---------------------|
| `items()`, `keepMarks()`, `currentSession()`, `sessions()`, `scanAttempts(for:)`, `chunks(job:)` | read | no |
| `resultInputs()` | items, keep marks and the revision in one actor turn | no |
| `revision()` | the counter | no |
| `loadLaunchState()` | meta, state rows (checksums verified), keep marks, current session, item COUNT; no item rows | no |
| `upsert(_:)` | writes items | yes, only for a new row or a row whose **results projection** changed (every `LibraryItem` field except `analyzedAt`, `scanAttempts`, `scanFailure`, `byteSize`, `isSizeEstimated`; album names compared as sorted arrays). An identical re-upsert does not |
| `checkpoint(items:chunk:session:)` | items, chunk, session in one transaction | yes, by the same rule as `upsert` for its items; the chunk and session writes never do |
| `deleteItems(_:)` | deletes items | yes, if any row was deleted |
| `setKeep(_:_:)`, `clearKeepMarks()` | keep marks | yes, if a mark was added or removed |
| `setSizes(_:)` | the size columns of existing rows only; never inserts | yes, once per batch, only if an item went from no size or an estimate to a measured size |
| `saveSession`, `createJob`, `saveChunks`, `deleteChunks` | scan bookkeeping | no |
| `saveState`, `deleteState` | a state row | no |
| `saveSnapshot(_:ifRevision:)` | the `results` row, only if the revision still equals the one given; returns whether it wrote | no |
| `sizes(for:)`, `stateInfo()` | read (`sizes(for:)` reads the size columns of the given photos only) | no |
| `deleteAllData()` | every row, every state row, and the pending writer's generation is bumped by the caller first | yes: the revision moves on and is never reused |

A table test in `ResultsRevisionTests` states "bump" or "no bump" for every mutating method, and fails
if a method is added to the protocol without a row. The only path that writes a measured size to an
existing row is `setSizes`; a test fails if any other path does.

## In-memory types (not stored)

| Type | Notes |
|------|-------|
| `LaunchPhase` | `opening`, `building`, `ready`, `failed`. Decides the first frame; Home never says "Scan Library" or "Your library looks clean" before `ready` |
| `StoreOpenStatus` | `ready` or `volatile(reason)`. Volatile means the store could not be opened and an in-memory store is in use; the files are untouched |
| `resultsBasis` | the revision the shown results are based on; compared with `revision()` to decide a rebuild |
| `pendingBuild` (shown as "N new results. Show" with `pendingNewCount`, spec 008) | a rebuilt result waiting for the next Home visit with no sheet open |
| `RemovalPlan` | the ids (sorted), the results subset (groups and slim items), per-category totals, created-at. Built when the confirm sheet opens, after the freshness gate. Immutable |
| `ReviewSession` | selection, decisions and results with the pure operations toggle, bulk select, keeper, removed, adopt |
| writer generation | an integer; a write handed in with an older number is refused (Delete All Data) |
| `ScanPauseReason.storageUnavailable` | in memory only (the session row does not store the pause reason): "Couldn't save progress" |

## Lifecycle of each saved row

| Row | Written when | Deleted by |
|-----|--------------|------------|
| `results` | after a rebuild and after sizes were measured, by compare-and-set | gate failure; Clear saved results; Delete All Data |
| `decisions` | debounced after each change; flushes at inactive, background, sheet open, before removal | Reset review choices; Start fresh; Delete All Data; checksum or version failure; per-entry expiry |
| `position` | debounced after a path change; restore counter writes | Reset review choices; Start fresh; Delete All Data; checksum or version failure; going Home on purpose writes an empty path |

"Delete saved data" (Settings, only when the store could not be opened) removes the store, its `-wal`
and its `-shm` files together, never one alone: commits sit in the `-wal` until a checkpoint, and
dropping it loses them with no error.

## Compatibility

- An existing store opens unchanged: two entities are added, no existing entity or column changes. A
  fixture written by the current build (`Fixtures/shipped-store`) is opened by `StoreMigrationTests`
  next to `previous-store`.
- The first launch after the update has no saved results, so the cold path builds them once; choices
  start empty; the position starts at Home.
- A build that finds a payload `version` or `formatVersion` it does not know ignores it (and replaces it
  with its own at the next save).
- Going back to an older build drops the two entities silently (same mechanism as a removed column);
  saved results, choices and place rebuild or reset. Accepted: only testing builds do this.
- The store folder keeps its protection and backup settings (Application Support, excluded from backup,
  the default file protection that allows writes after the first unlock). The `-wal` and `-shm` files are
  always copied, moved or deleted with the store.
