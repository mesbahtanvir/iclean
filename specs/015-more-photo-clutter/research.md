# Research: More Photo Clutter (015)

Each entry: what was decided, why, what else was weighed. Platform facts were checked against the
PhotoKit API the package already uses (`PhotoKitLibrary`, `BaselinePhotoKit`).

## R1. Which burst frame the person picked

- **Decision**: read `PHAsset.burstSelectionTypes` (`.userPick`, `.autoPick`) and
  `PHAsset.representsBurst` once per asset, into a new `AssetMetadata.burstPick: BurstPick?`
  (`userPick`, `autoPick`, `none`) and a `representsBurst` flag. The fetch already asks for every
  burst frame (`includeAllBurstAssets = true` in three places), so nothing changes in the fetch.
- **Rationale**: these are the only records Photos keeps of what the person chose; they are free
  to read with the asset and need no pixels, so a cloud-only burst still groups (spec edge case).
- **Alternatives**: deriving "picked" from the frame Photos shows (`representsBurst`) alone misses
  the case where the person picked several frames in the burst picker.

## R2. Keeping only the still of a Live Photo

- **Decision**: in one `PHPhotoLibrary.performChanges` block, for each Live Photo: read the
  `.photo` resource's bytes with `PHAssetResourceManager.requestData` (network off, as sizes are
  read today); `PHAssetCreationRequest.forAsset()` with `addResource(with: .photo, data:)`,
  `creationDate` and `location` copied; add the placeholder to every album the original is in
  (`PHAssetCollection.fetchAssetCollectionsContaining(_:with: .album)` then
  `PHAssetCollectionChangeRequest(for:).addAssets`); then `PHAssetChangeRequest.deleteAssets` on
  the originals, in the same block as the ordinary removals so iOS shows one confirmation.
- **Rationale**: PhotoKit has no request that removes a resource from an asset. The Photos app's
  "Live off" is an adjustment that leaves the movie in place and frees nothing. A new asset is the
  only way to free the space. One block gives one system dialog (spec FR-004a) and makes the
  creation and the deletion succeed or fail together.
- **Caption**: PhotoKit exposes no public way to read or write an asset's caption. The spec's
  clause "copies the caption" cannot be met; the spec is amended to say the caption is not
  carried and a Live Photo with a caption cannot be told apart. Recorded in the plan as the one
  spec amendment.
- **Shared content**: `PHAsset.sourceType == .typeCloudShared` marks items from shared albums; they
  are never listed. The iCloud Shared Library is not distinguishable with the APIs in use (items
  are fetched with the person's own); the spec is amended to name shared albums only.
- **Motion size**: the `.pairedVideo` resource's byte count, measured where `localByteSize` already
  walks the resources, kept apart from the total as `LibraryItem.motionByteSize`. Edited Live
  Photos (`.fullSizePairedVideo`) are never listed, so one resource type suffices.
- **The new still is not a stranger**: the trimmed asset's `LibraryItem` is written to the store
  under the new identifier with the original's analysis, size minus motion, and kind `.photo`
  before the change observer sees it; the original is dropped by the usual removal path. So no
  separate trim record is needed; the "Trim record" entity of the spec becomes this inherited
  item.
- **Alternatives**: editing the Live Photo to a still via `PHContentEditingOutput` (keeps the
  movie, frees nothing); exporting to a file and re-importing (same as chosen, more copies).

## R3. Screen recordings without opening a frame

- **Decision**: `PHAssetMediaSubtype.videoScreenRecording` becomes `ItemKind.screenRecording`,
  with `isVideo` true. Everything that treats a video as a video (`LargeVideosCategory`,
  `DuplicateVideoDetector`, `SizeMeasurer.measureVideos`, `ScanPlanner`'s metadata-only rule,
  `VisionDemand.isGroupable`, the video row) switches from `kind == .video` to `kind.isVideo`.
- **Rationale**: a kind is how screenshots are already told apart; it keeps the free app's rule
  (no frame opened) by construction, since recordings follow the same metadata-only path.
- **Migration**: stored items keep the raw kind string; a recording stored before this entry says
  "video". The quick check on app open already refreshes metadata of changed assets; this entry
  adds a one-time metadata refresh when the stored metadata version is older (a small
  `StoreMetaRecord` field), which re-reads kinds, burst picks and motion sizes for every item
  without touching pixels. Same mechanism carries R1 and R2's new fields.

## R4. Emptiness, the Dark measure

- **Decision**: `Emptiness.score(_:)` on the same `GrayImage` sharpness already builds: the share
  of pixels at the extremes (≤ 16 or ≥ 240 of 255) and the strongest-edge contrast from the
  existing `EdgeStats`. A photo is dark when extremes ≥ 0.97 and contrast <
  `Sharpness.featurelessEdgeContrast` (12), or extremes ≥ 0.995 whatever the contrast. Stored as
  `Analysis.emptiness: Double?` (the extremes share), with the contrast folded into the decision at
  analysis time as a flag `Analysis.isEmpty: Bool?`.
- **Rationale**: a Night mode street is dark on average but full of edges (contrast high), so it
  is spared by structure, which is what the spec asks. The lens-cap and pocket cases are flat.
  Reusing the grey image means no new decode (spec FR-008, SC-003).
- **Face veto**: Dark needs "no face found and Vision ran", as Unimportant does (011 FR-005). The
  analyzer's rule for the extra face pass (`UnimportantDetector.isCandidate`) is widened to a
  photo that is empty, so the pass runs for the candle-with-a-face case; sharp, non-empty, lonely
  photos still skip it.
- **Old items**: items analyzed before this entry have no emptiness. The next full scan
  re-analyzes items whose analysis predates the field (a "fill" pass: decode and grey image only,
  Vision only when empty). Until then Dark lists only what has been re-read; the category is
  simply smaller, never wrong.
- **Alternatives**: mean luminance thresholds (flags Night mode and candle shots); a Vision
  classifier (a new pass per photo, against FR-008).

## R5. Where the new categories sit, and what rebuilds

- **Decision**: `CleanupCategory` order becomes duplicates, bursts, similar, blurry, dark,
  unimportant, screenshots, screenRecordings, duplicateVideos, largeVideos, livePhotos. A new
  `CleanupCategory.action` (`.remove` / `.trim`) marks Live Photos; the builder assigns items to
  the first matching `.remove` category and then, separately, lets `.trim` categories see every
  item again (spec FR-007). `GroupType.burst` is added so the group screen can say "burst".
  `preselects` is true for bursts and dark, false for screenRecordings and livePhotos.
- **Similar**: `SimilarShotsDetector` drops the burst union and the `sameBurst` shortcuts at
  `medium`; a burst frame still pairs by prints like any photo. `BuilderVersion` is bumped and the
  new thresholds join `BuilderKey.currentThresholds`, so saved snapshots rebuild.
- **Keeper rule**: `KeeperRules.burstKeepers` in the spec's order: user picks, favourites, kept
  marks (passed in), best face among sharp frames, sharpest, `representsBurst`, first by capture
  order. Face quality is already demanded for burst frames (`VisionDemand`), so nothing new is
  asked of Vision.

## R6. One confirmation for removals and trims

- **Decision**: `RemovalPlan` carries `trims: Set<String>` beside the removal selection;
  `Remover` grows `summary` fields for trims (count, motion bytes) and `remove` passes both to a
  new `PhotoLibrary.apply(removing:trimming:) -> ChangeResult`, one block, one dialog.
  `CleanupSummary` gains `trimmedCount`, `trimmedAssetIDs`, `bytesFreedByTrim`. The sheet shows
  two sections and one button, "Remove 12 and Trim 5"; the receipt reports both.
- **Rationale**: 001 FR-012 wants one summary and one tap; iOS gives one dialog per
  `performChanges`, so both have to be in one block.
- **Failure**: a Live Photo whose still is not local is left out of the block before it starts
  and reported as "could not change" (001 FR-014: no download). If the block fails as a whole,
  nothing changed, as today.

## R7. Fixtures and the baseline

- **Decision**: `DemoPhotoLibrary`'s standard scenario gains two bursts (one with a user pick), six
  Live Photos (one long exposure, one favourite), three screen recordings and four dark shots
  (two pocket, one blown out, one Night-mode-like with edges, which must not be listed).
  `BaselineCatalogV5` adds the same in recipes; Live Photos are written with a `.pairedVideo`
  resource in `BaselinePhotoKit`, bursts with a shared `burstIdentifier` are not creatable through
  PhotoKit, so the baseline checks Bursts only on the Mac host tests with a fake library, and the
  device run covers the other three.
- **Rationale**: the baseline is the one check that runs on a device; where PhotoKit cannot seed a
  case, the host tests carry it, as 011 did for levels.
