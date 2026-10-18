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
| `addedDate` | Date? | When the item was added to the library; read from iOS 26, nil before and in stores written by earlier versions. Used to judge which copy's date is real (added 2026-10-18, specs/006-date-aware-keepers/spec.md) |
| `hasLocation` | Bool? | Whether the item has a location; nil means not known yet (earlier stores), never "none". Same use as `addedDate` |
| `analysisSource` | enum `localPreview` / `cloudPreview` / `notScanned` / `metadataOnly` | FR-014. `metadataOnly` marks a video in the free app: it is stored with its metadata only, for ranking, and its `Analysis` is nil (added 2026-10-18, see specs/004-phased-cleaning/spec.md FR-004a). It is not `notScanned`, which means a photo that could not be analyzed because only iCloud has it: `metadataOnly` is not a failure, is not counted as not scanned, and is not retried. With Pro, the next full scan analyzes it. |
| `dHash` | UInt64? | Duplicate candidate fingerprint (R3) |
| `thumbprint` | Data? | 16×16 grayscale miniature; confirms duplicates (R3) |
| `featurePrint` | Data? | Serialized Vision feature print (R3, R4) |
| `sharpness` | Double? | 0 (blurred) … 1 (sharp), `1 − blurEffect` (R5) |
| `aestheticsScore` | Double? | Second blur signal (R5) |
| `faceQuality` | Double? | Best face capture quality; similar-shots tie-break (R4) |
| `byteSize` | Int64? | Measured local size (R7) |
| `isSizeEstimated` | Bool | True when `byteSize` is an estimate (cloud-only) |
| `analyzedAt` | Date | |

**Validation**
- `dHash`, `featurePrint`, `sharpness` are nil when `analysisSource == .notScanned` or
  `.metadataOnly`.
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
| `notScannedCount` | Int | Shown to the user (FR-014); videos stored as `metadataOnly` are not counted |
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
| `type` | enum `duplicatePhotos` / `similarShots` | `duplicateVideos` is Pro only since 2026-10-18: the free app does not analyze videos (see specs/004-phased-cleaning/spec.md FR-004a) |
| `members` | [assetID] | ≥ 2 |
| `keepers` | Set<assetID> | ≥ 1 unless the user selects all and confirms the warning (FR-016) |

**Keeper rules**
- Duplicate photos (FR-008): every favorite is a keeper; otherwise highest
  resolution and quality, tie → oldest `captureDate`. *Amended 2026-10-18 by specs/006-date-aware-keepers/spec.md: among copies with different dates the copy whose date is most probably the real capture date is kept (impossible dates lose first, then resolution, then dates and details that look less reliable, then the earliest date, then file size, then the oldest).* (The video rule is Pro only since
  2026-10-18: the free app does not analyze videos, see specs/004-phased-cleaning/spec.md
  FR-004a.)
- Similar shots: every favorite is a keeper; otherwise highest `sharpness`, tie-break on
  face capture quality (R4).

### Category

`Duplicates`, `Similar`, `Blurry`, `Screenshots`, `Large Videos` (five in the free app).
With Pro there are six: `Duplicate Videos` sits between `Screenshots` and `Large Videos`
(Pro only since 2026-10-18: the free app does not analyze videos, see
specs/004-phased-cleaning/spec.md FR-004a).

**Category assignment** (an item appears in only one; first match wins):
`Duplicates → Similar → Blurry → Screenshots → Large Videos` (with Pro, Duplicate Videos
sits between Screenshots and Large Videos). Large Videos applies to videos only and ranks
them by file size, with no analysis.

**Flagging exclusions** (apply to every category): favorites, KeepMarks, items in shared
albums, items with `analysisSource == .notScanned` (except Screenshots and Large Videos,
which need only metadata). Items with `analysisSource == .metadataOnly` are videos and can
appear only in Large Videos in the free app. With Pro, the next full scan analyzes them and
they can then be grouped in Duplicate Videos.

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
