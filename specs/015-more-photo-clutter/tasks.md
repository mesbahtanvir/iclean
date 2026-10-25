# Tasks: More Photo Clutter

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [quickstart.md](quickstart.md)

Tests are part of every story here, as in 010 and 011: the spec's success criteria are test
totals and digests. Paths are from the repository root; `CK` is
`Packages/CleanupKit/Sources/CleanupKit`, `CKT` is `Packages/CleanupKit/Tests/CleanupKitTests`.

## Phase 1: Setup

- [X] T001 Read `CK/Models/Types.swift`, `CK/Results/ResultsBuilder.swift`, `CK/Removal/Remover.swift`, `CK/Library/PhotoKitLibrary.swift` (lines 140–165 and 355–420) and `iclean/App/AppModel.swift` (around `makeRemovalPlan`) so the shapes in data-model.md are placed exactly; note every `kind == .video` site (`grep -rn "kind == .video" Packages iclean`)

## Phase 2: Foundational (blocks every story)

- [X] T002 `CK/Models/Types.swift`: `ItemKind.screenRecording` with `isVideo = self == .video || self == .screenRecording` and `isStillImage = !isVideo`; `BurstPick` enum (`userPick`, `autoPick`, `none`); `AssetMetadata.burstPick: BurstPick?`, `representsBurst: Bool`, `isShared: Bool` (defaults nil/false/false); `Analysis.emptiness: Double?`, `isEmpty: Bool?`; `LibraryItem.motionByteSize: Int64?` and `stillByteSize`
- [X] T003 `CK/Models/Types.swift`: `CleanupCategory` cases in order `duplicates, bursts, similar, blurry, dark, unimportant, screenshots, screenRecordings, duplicateVideos, largeVideos, livePhotos`; `CategoryAction` (`remove`, `trim`) and `action` (only `livePhotos` is `.trim`); `preselects` false for `largeVideos`, `unimportant`, `screenRecordings`, `livePhotos`; `GroupType.burst`
- [X] T004 Replace every `kind == .video` with `kind.isVideo` where a video is meant: `CK/Grouping/LargeVideosCategory.swift`, `CK/Grouping/DuplicateVideoDetector.swift`, `CK/Scanning/SizeMeasurer.swift` (`measureVideos`), `CK/Scanning/VisionDemand.swift` (`isGroupable` stays photo/livePhoto), `iclean/Features/Category/VideoRow.swift:134`, `iclean/Mac/MacVideoTable.swift:175`, `iclean/Features/Category/CategoryFormatting.swift:32` (add the "Screen Recording" word)
- [X] T005 `CK/Library/PhotoKitLibrary.swift` `metadata(for:albums:)`: kind `.screenRecording` when `subtypes.contains(.videoScreenRecording)` (checked before `.video`); `burstPick` from `asset.burstSelectionTypes` (`.userPick` wins over `.autoPick`); `representsBurst`; `isShared = asset.sourceType.contains(.typeCloudShared)`
- [X] T006 `CK/Library/PhotoKitLibrary.swift` `localByteSize(for:)`: for a Live Photo, keep the `.pairedVideo` resource's bytes apart; return both through a new `localSizes(for:) -> (total: Int64, motion: Int64?)?` and have `localByteSize` call it; `CK/Scanning/SizeMeasurer.swift` and `MeasuredSize` carry `motion`; `Store.setSizes/sizes` carry it
- [X] T007 `CK/Store/LibraryItemRecord.swift`: optional columns `burstPick: String?`, `representsBurst: Bool?`, `isShared: Bool?`, `emptiness: Double?`, `isEmpty: Bool?`, `motionByteSize: Int64?`, mapped both ways and in the "changed" comparison; `CK/Store/StoreMetaRecord.swift`: `metadataVersion: Int?`; `CK/Store/SwiftDataStore.swift`: `refreshMetadata` writes the new fields
- [X] T008 (not needed: the quick check already refreshes every item whose stored metadata differs from the library's, `ScanPlanner` line 73, so the new fields fill on the next app open) Metadata refresh for older stores: in `CK/Scanning/ScanPlanner.swift` (or the quick check in `iclean/App/AppModel.swift`), when `metadataVersion < 2` fetch every item's metadata (`fetchItems(withIDs:)`) and sizes for Live Photos, `refreshMetadata`, set the version to 2; no previews. Shown as the quick check is
- [X] T009 `CK/Results/ResultsSnapshot.swift`: `BuilderVersion.current = 2`; `Item` gains `burstPick`, `emptiness`, `motionByteSize`, `isShared` (optional); `currentThresholds` gains `"burst", minimumFrames, "dark", extremes, flatExtremes, lowValue, highValue, "live", 1`
- [X] T010 `CK/Results/ResultsBuilder.swift`: two passes. Pass 1 over detectors whose `category.action == .remove` as today; pass 2 over `.trim` detectors with every item (ignore `assigned`), still dropping `protected` and keep-marked items; `CleanupResults.totals(for:)` sums `motionByteSize` for a `.trim` category; add `trimCategory(of:)`; `removing(_:)` also drops trimmed originals
- [X] T011 `CKT/Unit/StoreMigrationTests.swift`: a store from before opens, the new columns read as nil, `metadataVersion` nil triggers the refresh once; `CKT/Unit/ResultsSnapshotTests.swift`: round trip of the new `Item` fields and the new key string; `CKT/Unit/VideosAreNotAnalyzedTests.swift`: a `.screenRecording` item is metadata-only in the free app
- [X] T012 `swift test --package-path Packages/CleanupKit`; iOS simulator and macOS builds (`xcodegen generate` first) all green with nothing visible changed yet

**Checkpoint**: types, store and builder ready; each story below stands alone.

## Phase 3: User Story 1 — Bursts (P1) 🎯 MVP

**Goal**: every burst with two or more frames is one group in Bursts with the right keeper; Similar no longer unions by burst.

**Independent test**: `BurstDetectorTests` and the `BurstsFlowTests` UI flow pass; `ResultLevelTests` passes with the burst union gone.

- [X] T013 [P] [US1] `CK/Grouping/BurstDetector.swift`: `BurstThresholds.minimumFrames = 2`; group items by `metadata.burstID` (stills only), members in capture order, `GroupType.burst`, `needsAnalysis = false`; keepers from `KeeperRules.burstKeepers(_:keepMarks:)`; groups ordered by the keeper's capture date, newest first
- [X] T014 [P] [US1] `CK/Results/KeeperRules.swift` `burstKeepers(_:keepMarks:)`: all `burstPick == .userPick`; else favourites; else keep-marked; else, if any frame has `faceQuality`, the sharpest among frames with faces within 0.02 of the best face quality; else the sharpest; else `representsBurst`; else the first by capture order then id. `DefaultResultsBuilder` passes `keepMarks` to detectors that take them (add `keepMarks` to `detectLevelled`'s signature with a default)
- [X] T015 [US1] `CK/Grouping/SimilarShotsDetector.swift`: remove the `bursts`/`byBurst` union (lines 92–102) and the `sameBurst` shortcuts (lines 135–172, 227–233); `CK/Results/StandardPipeline.swift`: `BurstDetector()` after `DuplicatePhotoDetector`
- [X] T016 [US1] `CKT/Unit/BurstDetectorTests.swift`: 12-frame burst → one group of 12 with one keeper; user picks (two) both kept; favourite wins over sharpness; keep mark kept; face rule; sharpest; cloud-only frames group with `representsBurst` keeper; a single frame lists nothing; builder puts a burst frame in Bursts before Similar; `CKT/Unit/ResultLevelTests.swift`: rewrite the burst-union expectation (pairs by prints only); `CKT/Unit/BaselineHostTests.swift`: bursts in the fake library, digest updated
- [X] T017 [US1] `iclean/Shared/Formatting.swift`: title "Bursts", glyph `square.stack.3d.up`, caption "Several frames of one moment. Keep the best, remove the rest."; `iclean/Shared/CategoryStyle.swift` colour; `iclean/Features/Category/GroupDetailView.swift` says "burst" for `GroupType.burst`; `iclean/Mac/Sidebar.swift` lists it
- [X] T018 [US1] `iclean/App/DemoPhotoLibrary.swift` standard scenario: two bursts (5 frames with one `userPick`; 3 frames, one favourite); `icleanUITests/BurstsFlowTests.swift`: Home shows Bursts, two groups, the picked frame is the keeper, change keeper persists across relaunch (007); `icleanUITests/SimilarFlowTests.swift`: drop the burst-group expectation

## Phase 4: User Story 2 — Live Photos, Keep Still Only (P2)

**Goal**: Live Photos lists trimmable Live Photos with motion sizes; one confirmation removes and trims; the new still inherits the original's analysis.

**Independent test**: `LivePhotosCategoryTests`, `TrimRemoverTests` (fake library), `LivePhotosFlowTests`; the baseline's seeded paired videos are listed.

- [ ] T019 [P] [US2] `CK/Grouping/LivePhotosCategory.swift`: `category = .livePhotos`, `needsAnalysis = false`; lists `kind == .livePhoto` with `motionByteSize > 0`, not `isLongExposure`, not favourite, not `hasAdjustments`, not `isShared`; sorted by `motionByteSize` descending; `GroupType.single`
- [ ] T020 [P] [US2] `CK/Library/PhotoLibrary.swift`: `ChangeResult { removed, failed, trimmed: [String: String], trimFailed, cancelled }`; `apply(removing:trimming:) async -> ChangeResult`; default `remove(_:)` calls it with no trims; `CKT/Fakes/FakePhotoLibrary.swift` implements trims (new id, kind `.photo`, size minus motion)
- [ ] T021 [US2] `CK/Library/PhotoKitLibrary.swift` `apply(removing:trimming:)`: for each trim, read the `.photo` resource bytes with `PHAssetResourceManager.requestData` and `NetworkOffOptions.resource()` (skip into `trimFailed` on error, before the block); one `performChanges`: `PHAssetCreationRequest.forAsset()`, `addResource(with: .photo, data:, options:)`, `creationDate`, `location`; `PHAssetCollection.fetchAssetCollectionsContaining(_:with: .album, options:)` → `PHAssetCollectionChangeRequest(for:)?.addAssets([placeholder])`; then `deleteAssets` on removals plus trimmed originals; map `placeholderForCreatedAsset.localIdentifier` into `trimmed`; `userCancelled` → `cancelled`
- [ ] T022 [US2] `CK/Removal/RemovalGate.swift` and `RemovalPlan`: `trims: Set<String>` (selection in the `.trim` category, checked against the library like `ids`); `CK/Removal/Remover.swift`: `RemovalPreview.trimCount/trimBytes/trimIsEstimate`; `remove` calls `apply(removing:trimming:)`; `CleanupSummary.trimmedCount/trimmedAssetIDs/bytesFreedByTrim/trimFailedAssetIDs/newStillIDs`; `nothingSelected` only when both are empty
- [ ] T023 [US2] Inherited still: after a successful trim, `iclean/App/AppModel.swift` (or a `TrimRecorder` in `CK/Removal/`) upserts a `LibraryItem` per new id: original's metadata with `assetID` = new id, `kind = .photo`, `motionByteSize = nil`, `byteSize = stillByteSize`, same `analysis`, `analysisSource`; then the usual `removing(_:)` on the originals; the change stream's insert for the new id finds it already stored (no re-analysis)
- [ ] T024 [US2] `CKT/Unit/LivePhotosCategoryTests.swift`: filters (long exposure, favourite, edited, shared, no motion), order, totals use motion bytes, an asset may be in Duplicates and Live Photos (as keeper) but never when selected for removal; `CKT/Unit/TrimRemoverTests.swift` (RemoverTests pattern): preview counts, one `apply` call with both sets, summary fields, cancelled, trimFailed for a cloud-only still, inherited item stored, original removed from results; `CKT/Unit/ResultsBuilderGuaranteesTests.swift`: a favourite or keep-marked Live Photo is never in `livePhotos`
- [ ] T025 [US2] `iclean/Features/Confirm/ConfirmParts.swift`, `ConfirmSheet.swift`, `DoneView.swift`: a Trim section (count, motion size) under the removals; one button "Remove 12 and Trim 5" / "Trim 5" / "Remove 12"; body says once that the still stays and the Live Photo goes to Recently Deleted (014: nowhere else); receipt reports removed, trimmed, and the space from each; `iclean/Features/Category/CategoryBars.swift` and `CategoryView.swift`: the bar in Live Photos reads "Keep Still Only (5)" and opens the sheet for that category; `iclean/Features/Category/ItemCell.swift`: motion size on the row
- [ ] T026 [US2] `iclean/Shared/Formatting.swift`: title "Live Photos", glyph `livephoto`, caption "Live Photos whose motion you never play. Keep the still, drop the movie."; `CategoryStyle.swift` colour; `iclean/Mac/Sidebar.swift`, `MacCommands.swift` ("Keep Still Only" command), `Overview.swift`
- [ ] T027 [US2] `iclean/App/DemoPhotoLibrary.swift`: six Live Photos with `motionByteSize` (one long exposure, one favourite, one in an album); demo `apply` performs the trim like the fake; `icleanUITests/LivePhotosFlowTests.swift`: four rows largest first, none selected, select two → sheet shows Trim section and button text → receipt → the two are plain photos, the album one still in its album; `icleanUITests/RemovalScreensTests.swift`: section count assertion updated
- [ ] T028 [US2] `Packages/CleanupKit/Sources/BaselineKit/BaselineCatalogV5.swift` (copy V4, add): `BaselineKind.livePhoto`, recipes pairing a still with a short clip; `BaselinePhotoKit.swift` adds the clip as `.pairedVideo` with a shared content identifier; `BaselineValidator.swift` expects them in `livePhotos`; `BaselineModel.swift` `ExpectedCategory` gains the new categories

## Phase 5: User Story 3 — Screen Recordings (P3)

**Goal**: all screen recordings listed newest first, none selected, no frame opened.

**Independent test**: `ScreenRecordingsCategoryTests`, `ScreenRecordingsFlowTests`, the baseline's seeded recordings land in Screen Recordings and in nothing else.

- [X] T029 [P] [US3] `CK/Grouping/ScreenRecordingsCategory.swift` (ScreenshotsCategory pattern): `kind == .screenRecording`, newest first, `needsAnalysis = false`; `CK/Results/StandardPipeline.swift`: after `ScreenshotsCategory`
- [X] T030 [P] [US3] `CKT/Unit/ScreenRecordingsCategoryTests.swift`: listing and order; a recording among the 50 largest is in Screen Recordings not Large Videos; nothing preselected; free app: `analysisSource == .metadataOnly` and no analyzer call (VideosAreNotAnalyzedTests pattern)
- [X] T031 [US3] `iclean/Shared/Formatting.swift`: title "Screen Recordings", glyph `record.circle`, caption "Screen recordings, newest first."; `CategoryStyle.swift`; `iclean/Features/Category/CategoryView.swift:35` uses the video list layout for `.screenRecordings` too; `iclean/Mac/MacCommands.swift:109` "Select All Videos" for it; `iclean/Shared/Components.swift:298` counts it as a video category
- [ ] T032 [US3] `iclean/App/DemoPhotoLibrary.swift`: three `.screenRecording` items; `icleanUITests/ScreenRecordingsFlowTests.swift`: three rows, none selected, length and size, remove one; `BaselineCatalogV5.swift`: two recordings (`BaselineKind.screenRecording`, written with the screen-recording subtype where PhotoKit allows, else listed as a host-only expectation) expected in `screenRecordings`

## Phase 6: User Story 4 — Dark and pocket shots (P4)

**Goal**: flat near-black or near-white photos with no face, listed darkest first and selected; Night mode spared.

**Independent test**: `DarkDetectorTests` on synthetic images (`TestImages`), `DarkFlowTests`, the baseline's pocket shots listed and its Night-mode-like photo not.

- [ ] T033 [P] [US4] `CK/Analysis/Emptiness.swift`: `DarkThresholds` (`extremes 0.97`, `flatExtremes 0.995`, `lowValue 16`, `highValue 240`); `Emptiness.measure(_ gray: GrayImage, edges: EdgeStats) -> (share: Double, isEmpty: Bool)` where `isEmpty = share ≥ flatExtremes || (share ≥ extremes && edges.contrast < Sharpness.featurelessEdgeContrast)`
- [ ] T034 [US4] `CK/Analysis/Analyzer.swift` `DefaultAnalyzer`: build the grey image and `EdgeStats` once for sharpness and emptiness (refactor `Sharpness.score` to accept them); set `Analysis.emptiness/isEmpty`; request the face pass when `isEmpty` as well as for `UnimportantDetector.isCandidate`; `CK/Scanning/VisionDemand.swift` doc comment updated
- [ ] T035 [US4] `CK/Scanning/ScanPlanner.swift`: fill pass — on a full scan, an analyzed still with `analysis.emptiness == nil` is queued for re-analysis (preview, sharpness, emptiness, face pass only if empty; prints kept); `ScanChunk` needs no new mask
- [ ] T036 [US4] `CK/Grouping/DarkDetector.swift`: `category = .dark`, `needsAnalysis = true`; lists stills (`photo`, `livePhoto`) with `isEmpty == true`, `faceQuality == nil` and the face pass not skipped (`!skippedVision.contains(.faceQuality)`), not portrait, not long exposure, not favourite, not edited; sorted by `emptiness` descending; `confidence .lower` for cloud previews; `CK/Results/StandardPipeline.swift`: after `BlurDetector`, before `UnimportantDetector`
- [ ] T037 [US4] `CKT/Fakes/TestImages.swift`: `pocket(seed:)` (near-black with sensor noise), `blownOut(seed:)`, `nightStreet(seed:)` (dark with bright edges), `candle(seed:)`; `CKT/Unit/DarkDetectorTests.swift`: pocket and blown-out listed, night street not, face veto, protections, Blurry wins when both, order, cloud confidence; `CKT/Unit/AnalysisTests.swift`: emptiness values and the face pass requested for empty photos; `CKT/Unit/DeferredVisionTests.swift`: the fill pass plans only items without emptiness
- [ ] T038 [US4] `iclean/Shared/Formatting.swift`: title "Dark Photos", glyph `moon.zzz`, caption "Photos with nothing in them: pocket shots and lens caps."; `CategoryStyle.swift`; `iclean/App/DemoPhotoLibrary.swift`: two pocket shots, one blown-out, one night-street (must not be listed); `icleanUITests/DarkFlowTests.swift`: three rows selected, the fourth absent, remove flow; `BaselineCatalogV5.swift`: recipes `.flat(value:, noise:)` and `.darkEdges(seed:)`, expected `dark` and `none`; `BaselineHostTests` digest

## Phase 7: Polish and validation

- [ ] T039 `iclean/Resources/Localizable.xcstrings`: every new string; VoiceOver labels for the Trim section, the Keep Still Only bar and the new rows; `icleanUITests/AccessibilityTests.swift` allowance list for the new bar (014 lesson: a one-line button is reported as the button)
- [ ] T040 `scripts/lint.sh` on touched files; `scripts/check-no-network.sh`; `swift test --package-path Packages/CleanupKit`; iOS simulator and macOS builds; the full simulator UI suite
- [ ] T041 `scripts/run-baseline.sh` on the simulator and the phone (memory: answer the Photos prompt once); compare reports with `scripts/compare-baseline-reports.py`
- [ ] T042 `ScaleBench --store <large30k>` build time against 011's log; confirm no new preview decodes for Bursts, Screen Recordings and Live Photos; record the fill pass cost on a store from before
- [ ] T043 `specs/015-more-photo-clutter/validation-log.md` in the 011 style: digests before/after, counts per new category on the demo and bench libraries, timings, test totals; update `specs/011-result-levels/spec.md` with a one-line note that burst frames moved to Bursts (015), and `specs/001-photo-cleanup/spec.md` FR-007's category list
- [ ] T044 Memory and PR: `CLAUDE.md`/memory note on the trim path (one change block, inherited still); open the PR against `main` with the spec, plan and validation log linked

## Later (not in this entry)

- [ ] T050 Tune `DarkThresholds` on real libraries (the explorer, as 011 T030)
- [ ] T051 RAW+JPEG pairs and shared-album copies (spec brainstorm, tier 3)
- [ ] T052 Reasons on Dark rows ("flat · no face") like 011 T031

## Dependencies

- Phase 2 before every story. T002 → T003 → T004–T010 (T005–T008 may run in parallel after T002; T009–T010 after T003).
- US1 (T013–T018): T013 and T014 in parallel, then T015–T018. Independent of US2–US4.
- US2 (T019–T028): T019 and T020 in parallel, T021 after T020, T022 after T020, T023 after T022, T024 after T021–T023, UI (T025–T027) after T022, baseline (T028) any time after T019. Independent of US1, US3, US4.
- US3 (T029–T032): T029 and T030 in parallel, then T031–T032. Independent.
- US4 (T033–T038): T033 → T034 → T035 → T036 → T037 → T038. Independent.
- Phase 7 after the stories chosen for the PR.

## Parallel example

After Phase 2, four people (or four sessions in their own worktrees) can take US1, US2, US3 and US4 at once: they share `StandardPipeline.swift`, `Formatting.swift`, `CategoryStyle.swift`, `DemoPhotoLibrary.swift` and `BaselineCatalogV5.swift` as merge points only (one line or one block each), and nothing else.

## Implementation strategy

MVP is Phase 2 plus US1 (Bursts): the smallest change with the clearest win, and it carries the one amendment to existing behaviour (Similar). US3 (Screen Recordings) is the cheapest second step. US2 (Live Photos) is the largest and the only one that writes to the library; it can ship in its own PR. US4 (Dark) carries the threshold risk and the fill pass; ship it last, with the validation log.
