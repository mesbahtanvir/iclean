# Research: Blurry & Duplicate Photo Cleanup

**Feature**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-10-11

Each decision is checked against the constitution: everything on-device, no network, no
third-party runtime code.

## R1. Platform, language, UI

- **Decision**: Native iOS app in Swift 6 (strict concurrency), SwiftUI, minimum iOS 26.0,
  built with Xcode 27 / iOS 27 SDK. iPhone only.
- **Rationale**: Only native code gets full access to the Photos library through Apple's
  PhotoKit framework, Apple's on-device image analysis (Vision), and first-class
  accessibility (VoiceOver, Dynamic Type, Reduce Motion — FR-017a). iOS 26 runs on every
  iPhone from the last 4+ years (SC-001 target devices).
- **Alternatives considered**: React Native / Flutter (extra runtime layers and plugins to
  vet under Principle III; weaker Photos access); minimum iOS 18 (wider reach, but more
  OS versions to test for a new app with no users yet).

## R2. Reading the photo library without touching iCloud

- **Decision**: Use PhotoKit (`PHAsset`, `PHImageManager`). Every image request sets
  `isNetworkAccessAllowed = false` and asks for a ~512 px image. If PhotoKit returns no
  local image (`PHImageResultIsInCloudKey` / nil image), the item is counted as
  "not scanned" (spec FR-014 & edge cases). A single wrapper type is the only code that
  talks to PhotoKit, so the "no network" flag cannot be forgotten.
- **Rationale**: Implements clarification answer A: previews only, never download. A
  512 px preview is enough for duplicate and similarity fingerprints and adequate for
  obvious blur.
- **Alternatives considered**: Allowing network access for better blur accuracy
  (rejected by clarification); reading full-resolution originals when local (slower, no
  accuracy gain for duplicates; may be revisited for blur if SC-003 is missed).

## R3. Duplicate detection (photos)

- **Decision**: Two-stage:
  1. **Candidate**: 64-bit perceptual hash (dHash) of the grayscale 9×8 downscale.
     Group items whose hashes differ by ≤ 4 bits, plus matching aspect ratio.
  2. **Confirm**: Vision image feature print (`GenerateImageFeaturePrintRequest`) distance
     below a tight threshold, calibrated on the labeled test set.
  Edited assets (`PHAsset.hasAdjustments`) are never grouped with non-edited ones
  (FR-002). Implemented in-house, no third-party library.
- **Rationale**: dHash is fast, tolerant of resizing/recompression/format changes, and
  easy to bucket; the feature print rejects look-alikes that are not true copies, targeting
  < 1% false duplicates (SC-002).
- **Alternatives considered**: File checksum (misses re-saved copies); feature print
  only (slower, O(n²) comparisons); third-party hashing libraries (Principle III review
  burden for trivial code).

## R4. Similar shots

- **Decision**: Sort assets by capture date. Compare each asset only with neighbours taken
  within 60 seconds (and with PhotoKit burst groups via `burstIdentifier`). Link pairs
  whose Vision feature-print distance is under a looser "similar" threshold; groups are
  the connected sets. Items already in a duplicate group are excluded (category order rule).
  Best shot: favorite, else highest sharpness score, using Vision face capture quality
  (`DetectFaceCaptureQualityRequest`) as a tie-break when faces are present.
- **Rationale**: Time windows keep it near O(n), and similar shots are by nature taken
  close together.
- **Alternatives considered**: Global clustering of all feature prints (expensive and
  groups unrelated photos of similar scenes).

## R5. Blur detection

- **Decision**: Sharpness score = variance of the Laplacian on the 512 px grayscale
  preview (Accelerate / vImage), computed on the whole image and on the most detailed
  3×3 tile (so a sharp subject with a soft background still counts as sharp). Flag only
  when the score is below a strict threshold (FR-003). Where available, Vision's image
  aesthetics request (`CalculateImageAestheticsScoresRequest`) is used as a second
  signal: a photo must also score low to be flagged. Thresholds are calibrated on the
  labeled test set to hit SC-003 (≥ 85% recall, < 10% false flags).
  Excluded: portrait-mode photos (`PHAssetMediaSubtype.photoDepthEffect`) and
  long-exposure Live Photos (FR-003a). Results from cloud-only previews get a
  "lower confidence" label (FR-014).
- **Rationale**: Laplacian variance is the standard, explainable blur measure; requiring
  two signals keeps false flags low, matching the "only obviously blurry" answer.
- **Alternatives considered**: Custom Core ML blur model (needs training data and a model
  to ship; possible v2 if SC-003 is missed); Laplacian alone (more false flags on
  low-texture scenes like sky or walls).
- **Open item (verify on device)**: PhotoKit has no documented flag for the Live Photo
  "Long Exposure" effect. Task: confirm which `playbackStyle` / subtype values a
  long-exposure asset reports on iOS 26–27; if none is reliable, fall back to excluding
  Live Photos whose blur score is low only in the preview but which have a still
  sharp tile.

## R6. Screenshots, videos

- **Decision**:
  - **Screenshots**: `PHAssetMediaSubtype.photoScreenshot`, newest first, all pre-selected
    (FR-004a).
  - **Duplicate videos**: candidates have the same duration (± 0.5 s) and aspect ratio;
    confirmed by dHash + feature print of the local poster-frame thumbnail
    (FR-004b). Keeper: favorite, else largest pixel size, else oldest.
  - **Large videos**: top 50 by size (FR-004c), never pre-selected.
- **Rationale**: All of this works from metadata and local thumbnails, so cloud-only
  videos never need downloading.
- **Alternatives considered**: Sampling several frames with AVFoundation (needs the full
  local video; impossible for cloud-only videos without downloading).

## R7. Measuring "space freed"

- **Decision**: For items stored locally, size = sum of the bytes of the item's
  `PHAssetResource`s, read locally with `PHAssetResourceManager`
  (`isNetworkAccessAllowed = false`) and cached. For cloud-only items, size is estimated
  from pixel dimensions, duration and type, and the UI shows "about" sizes. Sizes are
  computed in the background after scanning and cached by asset id + modification date.
- **Rationale**: PhotoKit has no public file-size API; reading resources locally is
  documented and network-free. Undocumented key-value access to a private "fileSize"
  property is avoided (App Store and stability risk).
- **Alternatives considered**: Private `fileSize` key (rejected); showing no sizes
  (fails FR-007 / FR-015).

## R8. Removal

- **Decision**: `PHPhotoLibrary.performChanges` with `PHAssetChangeRequest.deleteAssets`.
  iOS then shows its own system confirmation and moves the items to Recently Deleted
  (FR-013). Our summary sheet (FR-012) comes first; the system prompt is a second,
  unavoidable confirmation. Large selections are submitted in batches of 500 so a
  failure only affects one batch; per-batch results feed the Cleanup Summary.
- **Rationale**: This is the only public way to delete, and it always goes to Recently
  Deleted — exactly what FR-013 needs.
- **Alternatives considered**: None available; apps cannot permanently delete.

## R9. Local storage for scan results

- **Decision**: SwiftData store in the app's Application Support folder, with
  `isExcludedFromBackup = true` and file protection
  `completeUntilFirstUserAuthentication`. CloudKit sync is not configured. Stores
  per-asset fingerprints, scores, sizes, keep marks, and scan progress. "Delete all data"
  (FR-018) deletes the store file.
- **Rationale**: Built-in, no dependency. Opting out of backup and sync satisfies the
  constitution's Data Handling Constraints.
- **Alternatives considered**: SQLite via a third-party wrapper (Principle III);
  plain JSON files (slow for 10k+ items, no queries).

## R10. Incremental scanning and app-open check

- **Decision**: Each cached record keeps the asset's `localIdentifier` and
  `modificationDate`. A scan only analyzes assets that are new or modified. On app open
  (FR-005a), a fetch compares the library with the cache and analyzes just the
  difference. Registering a `PHPhotoLibraryChangeObserver` keeps results in sync while
  the app is open (edge case "library changes during review"). Scanning runs only in the
  foreground; progress is saved every 100 items so it resumes after the app is closed.
- **Rationale**: Meets SC-001 (repeat scan < 30 s) and FR-006.
- **Alternatives considered**: `BGProcessingTask` background scanning (rejected by
  clarification: nothing in the background).

## R11. Performance budget

- **Decision**: Concurrent pipeline: PhotoKit image requests feed a bounded task group
  (≈ 4 concurrent analyses) running dHash, Laplacian and feature print. Target ≥ 20
  items/s on an iPhone 12-class device → 10,000 items in ≈ 8 min (SC-001). Analysis
  runs at `.userInitiated` priority and the scan pauses when the device reports serious
  thermal state.
- **Rationale**: Feature prints use the Neural Engine and take a few ms each; image
  loading dominates, so modest concurrency suffices.
- **Alternatives considered**: Full parallelism (thermal throttling, memory spikes).

## R12. Proving "no network" (Principle V)

- **Decision**: Three checks:
  1. **Static**: a script run in CI and before every PR fails if the source uses networking
     APIs (`URLSession`, `URLRequest`, `NWConnection`, `Network` framework, `CFNetwork`,
     `WKWebView`, `SFSafariViewController`, `CloudKit`, `isNetworkAccessAllowed = true`).
  2. **Runtime**: UI tests run the full scan → review → removal flow on a simulator with
     networking disabled and assert success (SC-006).
  3. **Manifest**: `PrivacyInfo.xcprivacy` declares no tracking and no collected data.
     The app has no network-related entitlements and no iCloud capability.
- **Rationale**: Makes the privacy promise testable and keeps it from decaying.
- **Alternatives considered**: Manual review only (decays over time).

## R13. Project tooling

- **Decision**: Core logic in a local Swift package `CleanupKit` (pure Swift, testable
  with `swift test` on macOS and on iOS simulator); app target generated from a
  `project.yml` with XcodeGen (a development-time tool only, which Principle III allows).
  Tests use Swift Testing; UI tests use XCUITest. No third-party runtime dependencies.
- **Rationale**: Fast unit tests without a simulator, and a readable, mergeable project
  definition instead of a hand-edited `.xcodeproj`.
- **Alternatives considered**: Plain `.xcodeproj` (merge conflicts, hard to review);
  Tuist (heavier tooling).

## R14. Test data for accuracy targets

- **Decision**: Build a labeled fixture set (≈ 500 images: duplicate pairs/triples at
  different sizes and formats, edited versions, burst sequences, sharp/blurry/portrait/
  night shots, screenshots, short duplicate videos), stored in the repo under
  `Fixtures/`. A seeding tool imports it into a simulator's photo library. Accuracy tests
  report recall and false-flag rates for SC-002 and SC-003.
- **Rationale**: Thresholds (R3–R5) need calibration, and the success criteria need a
  repeatable measurement.
- **Alternatives considered**: Public datasets downloaded at test time (adds a network
  dependency to the test process and licensing questions).
