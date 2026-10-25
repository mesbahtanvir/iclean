# iClean — App Platform Technical Design

**Status:** Draft v1
**Date:** 2026-08-12
**Companion to:** [DESIGN.md](DESIGN.md) (product) and [SCAN_PIPELINE.md](SCAN_PIPELINE.md) (the read path). This document owns the **write half** — where every trust and honesty promise actually executes: the commit engine, photo-library authorization, entitlements, telemetry, and the release checklist.

> **Superseded in part (spec 007).** The shipped app stores its data in SwiftData in the app's
> Application Support folder, not in GRDB, and not in an App Group container; there is no
> `commit_journal` table. A removal runs an immutable plan checked against the library when the
> confirm sheet opens, and results are rebuilt afterwards, instead of being recovered from a
> journal. See `specs/007-persistent-session/` and `specs/008-staged-cleanup-at-scale/`. The
> text below is the original design and is kept for its reasoning. Section 4, the paywall,
> describes nothing that ships: iclean is free, with no purchase (specs/016-free-photos-only/spec.md).

---

## 1. Module Architecture & Deployment Target

**Minimum iOS: 16.0.** Already required by persistent change history (`fetchPersistentChanges`), and aligned with the Face ID-locked Recently Deleted copy and the Duplicates-album competitive positioning.

Local SPM packages with one-way dependencies (each arrow = "may import"):

```
PhotoGateway  ←  ScanEngine  ←  ProposalStore  ←  CommitEngine ─┐
   (only pkg       (S0–S7,        (GRDB, owns        Entitlements ├─ ←  iCleanUI  ←  app target
    importing       UIKit-free)    schema +           (StoreKit 2) ┘      (SwiftUI)
    Photos)                        migrations)
FixtureKit (test support: golden libraries + gateway mock — imported by test targets only)
```

Rules: `ScanEngine` stays platform-agnostic so accidental UIKit use fails to compile; `iCleanUI` imports store and engine *protocols* only; nothing below `iCleanUI` imports SwiftUI. `PhotoGateway` is the single place `import Photos` appears.

## 2. The Commit Engine

The staging bin's contents become real deletions here. Every DESIGN.md §9.2 promise has its mechanism in this section.

### 2.1 Flow

```
staged proposals → allowance gate → re-validation → chunking → per-chunk atomic change block → receipt
```

1. **Allowance gate (at commit entry).** `lifetimeCommittedCount` lives in the Keychain (§4.3). If `count(staged) + lifetimeCommittedCount` exceeds the free allowance and the unlock isn't owned, the paywall interposes — with the under-allowance prefix still committable (DESIGN.md §2: declining never destroys triage work).
2. **Re-validation.** Immediately before each chunk: `PHAsset.fetchAssets(withLocalIdentifiers:)`; drop assets that are missing or whose `modificationDate > decidedAt`, writing `staging_note` rows (`droppedMissing` / `droppedModified`) that back the bin-screen notes.
3. **Chunking.** 500–1,000 assets per chunk (tune on device — Slidebox's freeze above ~100 items is the category's cautionary precedent; see SCAN_PIPELINE.md §14.4). **When more than one chunk is needed, the review screen says so up front: "iOS will ask you to confirm N times."** The one-dialog promise is per-chunk, stated honestly.
4. **One atomic change block per chunk.** A single `PHPhotoLibrary.performChanges` containing, in order: keeper inheritance — `PHAssetCollectionChangeRequest(for: album).addAssets([keeper])` for each user album a doomed member occupied, `PHAssetChangeRequest(for: keeper).isFavorite = true` where a doomed member was a favorite — then `PHAssetChangeRequest.deleteAssets(members)`. A change block is atomic: user-cancel of the system dialog throws `PHPhotosError(.userCancelled)` and rolls back the inheritance too, so **orphaned metadata writes are impossible**. Cancel preserves staging with no guilt copy (DESIGN.md §14.5).
5. **Crash-safe journal.** Before each `performChanges`, write `commit_journal(commitId, chunkIndex, assetIds, state='pending')`. On relaunch with a `pending` journal row, re-fetch that chunk's identifiers: absent ⇒ the chunk applied (mark `done`); present ⇒ it didn't (mark `aborted`, items stay staged). Idempotent recovery, no double-deletes.
6. **Own-delete reconciliation.** Outgoing identifiers are registered with the change machinery so S0 doesn't treat our own deletions as external mutations (they arrive as ordinary deletes; the journal tags them as ours).
7. **Receipt.** Actual bytes = Σ `fileSize` of assets *confirmed absent* post-commit (flagged approximate when `fileSizeIsEstimate`), never a device-free-space delta — nothing frees until Recently Deleted purges (DESIGN.md §3). Failed chunks surface as "N items couldn't be deleted" (`staging_note.commitFailed`) and stay staged.

### 2.2 Schema (lives in `ProposalStore` alongside SCAN_PIPELINE.md §4)

```sql
commit_journal (
  commitId TEXT, chunkIndex INT, assetIds BLOB,
  state INT,                -- pending / done / aborted
  createdAt REAL, resolvedAt REAL,
  PRIMARY KEY (commitId, chunkIndex)
)
```

## 3. Photo Library Authorization

An `AuthGate` component gates pipeline start on `PHPhotoLibrary.authorizationStatus(for: .readWrite)`. **Always `.readWrite`** — the app deletes and writes album membership; never request add-only.

| State | Behavior |
|---|---|
| `.notDetermined` | Show the safety-nets pre-prompt screen (DESIGN.md §10 first-run), then `requestAuthorization(for: .readWrite)`. |
| `.authorized` | Start the pipeline. |
| `.limited` | Start the pipeline over the selection, with honesty scoping (below). |
| `.denied` | Zero-state screen + Settings deep link (`UIApplication.openSettingsURLString`). |
| `.restricted` | Same zero-state, *without* promising Settings can fix it (parental controls). |

**Limited-access honesty scoping** (answers DESIGN.md §14.1):

- `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES` in Info.plist — we own the moment, not the OS re-prompt.
- Every number is scoped: header pill reads "Scanning the N photos you've shared"; Plan cards say "of your selection"; reclaimable-GB claims never extrapolate to the unseen library.
- "Add photos" affordance via `presentLimitedLibraryPicker(from:)`; selection changes arrive as ordinary S0 diffs (the pipeline is already agnostic).
- The full-access upgrade ask is a **trust moment**: shown once, after the first successful commit ("iClean cleaned what you shared. Want it to check the rest? You approve everything, as always."), via the Settings deep link. Never nagged again.

## 4. Entitlements & Paywall (StoreKit 2)

### 4.1 Product

One non-consumable: `com.iclean.unlock.lifetime`. Family Sharing **enabled** on the product in App Store Connect — `Transaction.currentEntitlements` then includes family members' transactions automatically (answers DESIGN.md §14.9's purchase half).

### 4.2 Machinery

- `Product.products(for:)` → `product.purchase()`; accept only `VerificationResult.verified` transactions.
- A `Transaction.updates` listener task starts at app launch, before any UI.
- `Transaction.currentEntitlements` checked at launch; the resulting bool cached in Keychain (`kSecAttrAccessibleAfterFirstUnlock`) so offline devices stay unlocked. `revocationDate` (refunds) clears the cache.
- Restore = a button calling `AppStore.sync()` (required by review guidelines; also the Family Sharing path).

### 4.3 Allowance integrity

`lifetimeCommittedCount` lives in the **Keychain**, surviving delete/reinstall. Accepted residual risk, documented deliberately: a device wipe or new Apple ID re-earns one free session (~100 items) — bounded, and not worth a server. Explicitly do **not** sync it via iCloud KVS: that would dent "nothing leaves your phone."

## 5. On-Device Telemetry & Adaptation State

DESIGN.md promises per-card decision-time instrumentation (§11), protection-surfacing validation (§4.11), and restore-as-regret ground truth (§9.5). All of it lives in the same GRDB database:

```sql
telemetry_event (kind TEXT, paramsJSON TEXT, at REAL)   -- ring-buffered, ~90-day cap
user_state (key TEXT PRIMARY KEY, value BLOB)
  -- trust-ladder facts: sessions completed, first-commit timestamp,
  -- per-family unlocks; user_calibration lives in SCAN_PIPELINE.md §7
```

Recorded: card dwell time, session length and exit point, per-family approval/restore rates, rule-offer outcomes. **Hard rule, stated here and enforced by the module graph (no networking dependency below `iCleanUI`): no analytics SDK, no network egress, ever.** This is what lets the App Store nutrition label read **"Data Not Collected"** and the trust footer say "nothing leaves your phone" without an asterisk. Support diagnostics are a user-initiated JSON export via the share sheet, never automatic.

## 6. Widget & Notification Hooks (built at v1.0, used at v1.x)

- The GRDB file lives in an **App Group container** (`group.<bundleid>.shared`) from day one — the v1.x widget needs headline numbers, and container migrations are painful later.
- The widget extension **never opens the database** (WAL + file-protection hazards). The app rewrites a tiny `widget-snapshot.json` (reclaimable GB, pending count, last-updated) into the group container after each scan batch and commit; the WidgetKit timeline reads only that.
- Notification scheduling (threshold-gated, DESIGN.md §11) reads the same snapshot logic.

## 7. Release & Privacy Checklist

- **`PrivacyInfo.xcprivacy`** (mandatory): `NSPrivacyTracking = false`; `NSPrivacyCollectedDataTypes` empty (§5 is what makes that true); `NSPrivacyAccessedAPITypes` covering at minimum UserDefaults (CA92.1) and file-timestamp APIs (C617.1 — SQLite/GRDB touch these); add disk-space (E174.1) only if the receipt ever reads free space. Verify GRDB's own bundled manifest aggregates correctly in Xcode's privacy report.
- **Info.plist:** `NSPhotoLibraryUsageDescription` written to the honesty bar — "iClean scans your library on this device to find duplicates and junk. Nothing is uploaded, and nothing is deleted without your confirmation." Plus `PHPhotoLibraryPreventAutomaticLimitedAccessAlert = YES` (§3) and `BGTaskSchedulerPermittedIdentifiers = [com.iclean.scan.processing]` (registration silently fails without it — SCAN_PIPELINE.md §8).
- `ITSAppUsesNonExemptEncryption = false`.
- App Review posture: cleaner category draws Guideline 4.3/2.3.1 scrutiny — GB claims must be reproducible (they are, by §2.7's receipt math); sensitive-content detection posture per DESIGN.md §4.10.

## 8. Open Questions

1. `deleteAssets` chunk-size validation on device (shared with SCAN_PIPELINE.md §14.4 / DESIGN.md §14.5) — chunk size directly shapes the "confirm N times" UX.
2. Verify `commit_journal` recovery semantics against real `performChanges` partial-failure behavior (does a thrown error ever leave a partial apply? Assumed no — validate).
3. Keychain allowance persistence across "erase all content" restores — confirm the accepted-risk boundary.
4. Whether the widget snapshot suffices for a lock-screen gauge (WidgetKit timeline freshness limits).
