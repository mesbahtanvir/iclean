# Data Model: Blurry & Duplicate Photo Cleanup

**Feature**: [spec.md](spec.md) | **Research**: [research.md](research.md)

Everything here is stored only on the phone, in the local store described in research R9
(excluded from backup, never synced). The photos themselves stay in the Photos library;
iclean stores only identifiers and analysis results.

## Entities

### LibraryItem (cached analysis of one Photos asset)

| Field | Type | Notes |
|-------|------|-------|
| `assetID` | String | PhotoKit `localIdentifier`. **Unique key.** |
| `kind` | enum `photo` / `screenshot` / `video` / `livePhoto` | From media type + subtype |
| `captureDate` | Date? | `creationDate` |
| `modificationDate` | Date? | Used to detect changes (re-analyze when it differs) |
| `pixelWidth`, `pixelHeight` | Int | |
| `duration` | Double? | Videos only, seconds |
| `isFavorite` | Bool | Favorites are never flagged (FR-008, edge cases) |
| `hasAdjustments` | Bool | Edited; never grouped with unedited copies (FR-002) |
| `isPortrait`, `isLongExposure` | Bool | Excluded from blur (FR-003a) |
| `burstID` | String? | PhotoKit burst identifier |
| `albumNames` | [String] | User-made albums containing the item (album badge) |
| `analysisSource` | enum `localPreview` / `cloudPreview` / `notScanned` | FR-014 |
| `dHash` | UInt64? | Duplicate candidate fingerprint (R3) |
| `featurePrint` | Data? | Serialized Vision feature print (R3, R4) |
| `sharpness` | Double? | Laplacian score (R5) |
| `aestheticsScore` | Double? | Second blur signal (R5) |
| `byteSize` | Int64? | Measured local size (R7) |
| `isSizeEstimated` | Bool | True when `byteSize` is an estimate (cloud-only) |
| `analyzedAt` | Date | |

**Validation**
- `dHash`, `featurePrint`, `sharpness` are nil when `analysisSource == .notScanned`.
- Re-analysis is required when the asset's current `modificationDate` differs from the
  stored one.

### KeepMark

| Field | Type | Notes |
|-------|------|-------|
| `assetID` | String | **Unique.** References LibraryItem. |
| `createdAt` | Date | |

An item with a KeepMark is never flagged in any category (FR-011). Marks can be cleared
individually or all at once.

### ScanSession

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | |
| `kind` | enum `full` / `quickCheck` | FR-005a |
| `state` | enum (see below) | |
| `startedAt`, `finishedAt` | Date / Date? | |
| `totalItems` | Int | |
| `processedItems` | Int | Saved every 100 items (R10) |
| `notScannedCount` | Int | Shown to the user (FR-014) |
| `lastProcessedAssetID` | String? | Resume point |

**State transitions**

```text
idle ──start──▶ running ──pause──▶ paused ──resume──▶ running
                  │  ▲                │
                  │  └─ app relaunch ─┘ (an interrupted running session resumes)
                  ├──stop──▶ stopped
                  └──finish─▶ completed
```

Only one session can be `running` or `paused` at a time.

## Derived (computed at review time, not stored)

Groups and categories are rebuilt from LibraryItems after each scan, so they always
match the current library.

### Group

| Field | Type | Notes |
|-------|------|-------|
| `id` | String | Stable: hash of sorted member asset IDs |
| `type` | enum `duplicatePhotos` / `similarShots` / `duplicateVideos` | |
| `members` | [assetID] | ≥ 2 |
| `keepers` | Set<assetID> | ≥ 1 unless the user selects all and confirms the warning (FR-016) |

**Keeper rules**
- Duplicate photos/videos (FR-008): every favorite is a keeper; otherwise highest
  resolution and quality, tie → oldest `captureDate`.
- Similar shots: every favorite is a keeper; otherwise highest `sharpness`, tie-break on
  face capture quality (R4).

### Category

`Duplicates`, `Similar`, `Blurry`, `Screenshots`, `Duplicate Videos`, `Large Videos`.

**Category assignment** (an item appears in only one; first match wins):
`Duplicates → Similar → Blurry → Screenshots`. Duplicate Videos and Large Videos apply to
videos only; a video in a duplicate group is not listed again in Large Videos.

**Flagging exclusions** (apply to every category): favorites, KeepMarks, items in shared
albums, items with `analysisSource == .notScanned` (except Screenshots and Large Videos,
which need only metadata).

### Selection (review state, kept in memory and saved with the session)

| Field | Type | Notes |
|-------|------|-------|
| `selected` | Set<assetID> | Items to remove |

**Default selection** (FR-010a): every flagged non-keeper item in every category is
selected, except Large Videos (never pre-selected).

### CleanupSummary (result of one removal)

| Field | Type | Notes |
|-------|------|-------|
| `requestedCount` | Int | |
| `removedCount` | Int | |
| `bytesFreed` | Int64 | Only items actually removed |
| `isEstimate` | Bool | True if any removed item had an estimated size |
| `failedAssetIDs` | [String] | Shown to the user (edge case "Removal fails") |
| `byCategory` | [Category: (count, bytes)] | For the summary sheet (FR-012) |

## Relationships

```text
LibraryItem 1 ── 0..1 KeepMark
LibraryItem * ── 0..1 Group (as member)        (derived)
Group       1 ── 1    Category                 (derived)
ScanSession   processes many LibraryItems
```
