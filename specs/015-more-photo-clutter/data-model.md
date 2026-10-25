# Data model: More Photo Clutter (015)

Changes to the types in `Packages/CleanupKit`. Everything is on-device; the store is the existing
SwiftData store. New fields are optional so older stores open.

## Enumerations

- `ItemKind` adds `screenRecording`. `isVideo` is `self == .video || self == .screenRecording`;
  `isStillImage` stays `!isVideo`.
- `BurstPick` (new): `userPick`, `autoPick`, `none`.
- `CleanupCategory` becomes `duplicates, bursts, similar, blurry, dark, unimportant, screenshots,
  screenRecordings, duplicateVideos, largeVideos, livePhotos` (assignment order). Adds
  `action: CategoryAction` (`.remove` for all but `livePhotos`, which is `.trim`). `preselects`
  is false for `largeVideos`, `unimportant`, `screenRecordings`, `livePhotos`.
- `GroupType` adds `burst`.

## AssetMetadata (+3)

| Field | Type | Source | Why |
|---|---|---|---|
| `burstPick` | `BurstPick?` | `PHAsset.burstSelectionTypes` | keeper rule 1 |
| `representsBurst` | `Bool` | `PHAsset.representsBurst` | keeper fallback |
| `isShared` | `Bool` | `PHAsset.sourceType == .typeCloudShared` | Live Photos veto |

`kind` now takes `.screenRecording` from `PHAssetMediaSubtype.videoScreenRecording`, checked
before `.video`.

## Analysis (+2)

| Field | Type | Why |
|---|---|---|
| `emptiness` | `Double?` | share of pixels at the extremes; nil before this entry |
| `isEmpty` | `Bool?` | the Dark decision made at analysis time (extremes and contrast) |

Both are kept by `withoutFingerprints` (a screen sorts Dark by `emptiness`).

## LibraryItem (+1)

| Field | Type | Why |
|---|---|---|
| `motionByteSize` | `Int64?` | the `.pairedVideo` resource's size; Live Photos row and total |

`effectiveByteSize` is unchanged (whole asset). `stillByteSize` = `effectiveByteSize -
(motionByteSize ?? 0)`, what the new still will take.

## Store records

- `LibraryItemRecord`: `burstPick: String?`, `representsBurst: Bool?`, `isShared: Bool?`,
  `emptiness: Double?`, `isEmpty: Bool?`, `motionByteSize: Int64?`. All optional: lightweight
  migration.
- `StoreMetaRecord`: `metadataVersion: Int?`. Below 2, the app refreshes every item's metadata once
  (kinds, burst picks, shared flag, motion sizes); no pixels.
- `ScanPlanner`: an analyzed still whose `emptiness` is nil is queued for the fill pass on the next
  full scan.

## Results

- `ResultsSnapshot.Item` gains the fields above that a screen reads: `burstPick`, `emptiness`,
  `motionByteSize`, `isShared`. `Category` is unchanged. `BuilderVersion.current` → 2;
  `BuilderKey.currentThresholds` gains `"burst"`, `"dark", extremes, flatExtremes` and the Live
  Photos rule version.
- `CleanupResults.totals(for:)` for a `.trim` category sums `motionByteSize` instead of
  `effectiveByteSize`.
- `DefaultResultsBuilder`: two passes. Pass 1 over `.remove` detectors as today. Pass 2 over
  `.trim` detectors sees every item (not `assigned`), still honours `protected` (favourites,
  keep marks are never trimmed).

## Removal

- `RemovalPlan`: adds `trims: Set<String>`.
- `RemovalPreview`: adds `trimCount`, `trimBytes` (motion), `trimIsEstimate`.
- `CleanupSummary`: adds `trimmedCount`, `trimmedAssetIDs`, `bytesFreedByTrim`,
  `trimFailedAssetIDs`, `newStillIDs: [String: String]` (original → new).
- `PhotoLibrary`: adds `apply(removing: [String], trimming: [String]) async -> ChangeResult`
  with `removed`, `failed`, `trimmed: [String: String]`, `trimFailed`, `cancelled`. `remove(_:)`
  stays as `apply(removing:trimming: [])`.
- `Store.upsert` is called with the new stills (inherited analysis, kind `.photo`,
  `motionByteSize` nil, `byteSize` = still size) before the change stream delivers the deletion.

## Thresholds (new, in `BuilderKey`)

| Name | Value | Meaning |
|---|---|---|
| `DarkThresholds.extremes` | 0.97 | share at the extremes, with no structure |
| `DarkThresholds.flatExtremes` | 0.995 | share at the extremes, structure ignored |
| `DarkThresholds.lowValue` / `highValue` | 16 / 240 | the extremes, of 255 |
| `BurstThresholds.minimumFrames` | 2 | frames in the library for a group |
