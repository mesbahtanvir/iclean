# Local matching, caching and ML roadmap

Produced 2026-10-17 by a structured brainstorm: four readers mapped the pipeline, five
proposers (local ML, caching, industry-standard matching, phased matching, systems)
generated 30 ideas, which were merged into 16, then each was checked for feasibility
against the iOS SDK headers, for redundancy against the code, and for value, and a final
critic reviewed the result. Every iPhone timing below is an estimate from Mac prototypes;
no on-device measurements exist yet, which is why measurement ranks first.

Read the "Critic review" section at the end before acting on any single number.

---

# iclean brainstorm: local ML, caching, standard matching, phased matching

*Timings marked (M4) come from release-build Mac prototypes on an M4 Max. The repo has no on-device timing, so every iPhone figure is an estimate. Targets: 10k first scan under 10 min, repeat scan under 30 s, duplicates at least 98% recall with under 1% false positives, blur at least 85% recall with under 10% false flags.*

## 1. Where the system is today

- **Scan** (`Scanning/ScanPipeline.swift`): durable 32-item chunks, 4-wide, oldest-first. Each photo gets one ≤512 px network-off PhotoKit preview with `resizeMode .fast`, so the delivered image may exceed 512 px. Since 2026-10-18 the free app does not analyze videos (video analysis is a one-time $2 Pro feature, not built yet), so videos keep metadata only (see specs/004-phased-cleaning/spec.md FR-004a). The diff uses `modificationDate` only, and there is no analysis version.
- **Signals** (`Analysis/Analyzer.swift`): computed sequentially per item.
  - 9x8 dHash and a 32x32 thumbprint (1,024 B).
  - Vision feature print: 768 floats, stored as 4,349 B of JSON.
  - Crete-Roffet sharpness at 256 px with two edge guards.
  - For photos, Vision aesthetics and face quality.
  - That is three separate `perform(on:)` calls and up to four grayscale redraws. There is no Accelerate or Core ML.
- **Duplicates** (`DuplicatePhotoDetector.swift`, `HashIndex.swift`): global and time-agnostic.
  - dHash within 10 bits through an 11-chunk index (32-64 buckets per chunk, about 10M checks at 10k).
  - Then aspect, `hasAdjustments`, thumbprint detail ≥0.85 and brightness ≤11, at 172 µs per pair (M4).
- **Similar** (`SimilarShotsDetector.swift`): already time-blocked.
  - Capture-date sort, a one-sided 60 s window, and burstID unions.
  - Link on feature print <0.1, or thumbprint ≥0.5 with feature print <0.15.
  - No sessions, no chain check, no size cap. Near-identical burst frames land in Duplicates first.
- **Blur and keepers**: flag when sharpness <0.55 and aesthetics <0. The similar keeper is the sharpest frame, with face quality only inside a 0.02 tie.
- **Results** are derived, never stored. `AppModel.reloadResults` loads about 5.4 KB of blobs per item (about 54 MB at 10k) and runs five detectors (a planned Pro version with Duplicate Videos was dropped 2026-10-24, 016) on the main actor at launch, foreground and scan end. M4: 0.6-1.5 s to load, 0.3-2 s to build.
- **quickCheck** refetches every PHAsset and album member. `PHPersistentChangeToken` and `PHCachingImageManager` are unused.
- **Biggest costs** are unmeasured on device. On the Mac, non-Vision CPU is about 1.4 ms per photo and three Vision calls take about 12 ms, so analysis is Vision- and PhotoKit-bound.
- **Accuracy** is 100%/0% on synthetic fixtures only, and no real-photo labels exist.

## 2. Proposals

### Local ML

#### P01 Fused Vision pass, kind gates, one luma plane
Run feature print, aesthetics and faces through one `ImageRequestHandler` with `perform(repeat each T)` (`Analyzer.swift:18-27`). Add a per-request fallback, because one throw fails the pack. Skip screenshots (a new `AnalysisSource` case, not `.notScanned`). Videos drop the feature print. **Moot in the free app since 2026-10-18:** it does not analyze videos at all (video analysis is a Pro feature, one-time $2, not built yet). Aesthetics runs only when sharpness is below about 0.65. Build the 9x8 and 32x32 miniatures from one ≤256 px plane with `vImageScale_Planar8`. Keep the scalar `BlurEffect` and skip Neural Engine pinning.
- Gain: Vision 11.9 → 4.9 ms per photo, about 40% less compute (M4). Copy dHash flips drop from 3.2 to 0.4 bits.
- Effort: M; re-validating thresholds dominates.
- Risks: fingerprints change by about 10 bits, so it needs P08's stamp and one rescan. A vImage box blur measured 4x slower. Touching `supportedComputeStageDevices` aborted at dyld load.
- Verdicts: partly feasible; only the non-photo gate exists; I3/E3.
- Measure: calibration dump before and after, plus the Accuracy suites.

#### P03 Subject-aware blur and lens smudge (defer)
Score blur on a saliency crop and add `DetectLensSmudgeRequest` (iOS 26) as a haze rule. Probes undercut both. Saliency covered 45-76% of synthetic frames. An unscaled 512 px crop scored fully blurry photos 0.61-0.63, above the 0.55 threshold. Smudge confidence tracked defocus and bokeh. Haze is the one class nothing catches today.
- Gain: unproven; synthetic targets are already 100%/0%.
- Effort: M, with three thresholds to calibrate.
- Risks: re-flags bokeh, mislabels blur, iOS 26 only.
- Verdicts: feasible; new; I2/E3.
- Measure: at least 15 real bokeh, missed-focus and haze photos each.

#### P04 Utility and subtype flags
Store `isUtility` (computed, then discarded at `Aesthetics.swift:8-10`). Read `.videoScreenRecording`, `.photoAnimation` and `.photoPanorama` into `AssetMetadata`. Animations and panoramas become blur exclusions, and recordings get a Large Videos label. Treat `isUtility` as a tie-breaker, not a hard exclusion, because accidental pocket shots look utility-like. Defer document segmentation and the "looks like a screenshot" section: the gate would fire on 20-35% of photos, and preselection is per category.
- Gain: untagged-screenshot coverage; headline numbers near zero.
- Effort: S for flags, M for the section.
- Risks: a hard exclusion could cut blur recall; backfill needs a version stamp.
- Verdicts: feasible; new; I2/E3.
- Measure: log `isUtility` rate by kind in one scan (tagged screenshots about 100%, camera under 15%).

#### P05 Burst-pick keeper
Read `representsBurst` and `burstSelectionTypes`; only `burstIdentifier` is read today (`PhotoKitLibrary.swift:92`). Store them as `burstRole`. A metadata-only `BurstGrouper` picks the keeper in this order: favorite, userPick, autoPick, representative, sharpest. Defer the landmarks, eyes-open, yaw and horizon z-score kernel: eye aspect ratio is noisy for faces under 40 px, and no face fixtures exist.
- Gain: the keeper matches the camera or user pick (SC-007). Few pair tests are saved, since intra-burst pairs already short-circuit.
- Effort: S for picks, M for the kernel.
- Risks: needs an FR-008 amendment and `needsAnalysis=false`, because the builder drops notScanned items. Imported bursts report `.none`.
- Verdicts: partly feasible; new; I3/E4.
- Measure: KeeperAccuracyTests with burst roles, and a labelled best-frame set with faces before any kernel.

#### P06 Learned quality head
Train offline a head over the 768 feature-print floats plus scalars. Ship the weights and evaluate with `vDSP` (4.7 µs per photo). Core ML measured 0.65-0.9 ms, and a pre-compiled `.mlmodelc` under `.process` breaks SwiftPM. The rules stay as fallback. The embedding does carry blur: logistic regression reached recall 0.91 and false-positive rate 0.05 on 125 synthetic labels. A probe also found a rule defect: the featureless guard let 64 of 138 heavy blurs through.
- Gain: calibrated probabilities; an estimated +3-10 pp recall at 10% false flags, mostly from real labels.
- Effort: L, dominated by labelling.
- Risks: a synthetic-trained head can invert guards; edge stats need storing; Vision revision drift.
- Verdicts: partly feasible; new; I3/E4.
- Measure: go/no-go on at least 300 labelled photos with scene-grouped CV. Build only if the embedding beats refit scalars by at least 3 pp.

### Local caching

#### P08 Versioned records, raw feature prints
Slice A: add `analysisVersion` and a per-signal success mask. Store the feature print as raw Float32 (3,072 B vs 4,349 B). Compute `vDSP_distancesq`; Vision's distance is exactly squared L2, so thresholds carry over. `FeaturePrintObservation` can't be rebuilt from bytes, so the cache moves to `[Float]` with a JSON fallback. `ScanPlanner` recomputes only stale or failed signals. Slice B (hot/cold split, `storedKeys()`) only if a device trace demands it.
- Gain: unblocks P01, P02, P06, P07 and P12. B's diff is only 1.2-1.8x faster, and relationship faulting is 3-10x slower.
- Effort: A S/M, B M.
- Risks: one forced rescan per bump. Keep marks must survive a wipe. B's projection must carry full metadata or favorite refresh breaks.
- Verdicts: partly feasible; new; I2/E3.
- Measure: raw vs `distance(to:)` within 1e-6, a migration test from the current schema, and a zero-change rescan analyzing 0 items.

#### P09 PhotoKit I/O pattern
- A: keep the chunk's `PHAsset`s from `fetchItems(withIDs:)` instead of a per-item `PHAsset.fetchAssets` (`PhotoKitLibrary.swift:109-116`).
- B: `.exact` 512 vs `.fast` (may deliver about 1008 px). Decide on device, because blur calibration depends on it.
- C: `PHCachingImageManager` look-ahead, only if profiling shows an idle gap. Options must match exactly.
- D: a UI `ThumbnailCache` with degraded-first delivery.
- Gain: realistically 5-12% of a first scan, not 1.3-2x; D is UX.
- Effort: A S, B-D M.
- Risks: `.exact` shifts blur calibration; prefetch adds a cancellation path beside the pause and thermal races.
- Verdicts: feasible; new; I2/E3.
- Measure: signpost the request-to-callback share. Ship only with at least 5% wall-time gain and an on-device sharpness delta report.

#### P10 Off-main results, slim items, snapshot
Move `buildResults` off the main actor (`AppModel.swift:96-101`). Detectors are already `Sendable`, so an engine actor with `Task.checkCancellation` between detectors, keeping old results visible, is small. Then slim `CleanupResults.items` to display summaries. Persist a snapshot for warm start (about 45 ms to decode 4k items, M4). `PHAssetResource.dataSize` is iOS 27 only, so no gain on your iOS 26 phone. Before building: size upserts must not invalidate the snapshot, selection must merge instead of reset, and the comparison must use whole results, not group IDs.
- Gain: main thread freed for 0.3-2 s (M4). First paint about 0.15 s vs 2-6 s (estimate). Resident results 54 MB → under 2 MB.
- Effort: M; off-main alone is S.
- Risks: a stale snapshot shows deleted assets; a new race against scan completion; Debug builds run 50-150x slower.
- Verdicts: partly feasible; new; I3/E3.
- Measure: Release timing at 10k/30k with clustered hashes, main-thread hang ≤100 ms, snapshot round-trip equality.

#### P11 Change tokens, then a match graph
Slice A: persist `PHPersistentChangeToken`.
- `quickCheck` asks `fetchPersistentChanges(since:)` for changed IDs and caches the album map.
- It falls back to a full diff on token expiry, Limited access and full scans.
- It reuses `fetchAllItems` options and advances the token inside the checkpoint.
- Also upgrade `.cloudPreview` items when the original arrives; they are never retried today.

Slice B, a persisted match graph, stores edges as packed blobs per session (per-row SwiftData costs 325 µs to write and 47 µs to read). It needs P14 and P08.
- Gain: a zero-change foreground drops from full fetch, album walk and two store loads (estimated 0.5-3 s or more) to one token query. B makes results independent of library size.
- Effort: A M, B L.
- Risks: token expiry. Immutability of unedited originals is unverified. Edges can drift from items. Scan order is oldest-first, so newest-first changes the resume tests.
- Verdicts: partly feasible; new, except the full-scan notScanned retry; I3/E5.
- Measure: delta-vs-full end-state equivalence (hidden and burst assets), an incremental == batch property test, zero-change foreground under 0.5 s.

### Industry-standard matching

#### P12 Duplicate kernel
- (c) Precompute zero-mean unit-norm raw and high-pass `[Float]` vectors per touched item (`vDSP_vfltu8`, `vDSP_vswsum`, `vDSP_dotpr`) and cache them by asset. Run gates cheapest first: mean difference, exact MAD, then correlation. In `SimilarShotsDetector`, decide on feature-print distance first and use the thumbprint only in the 0.1-0.15 band.
- (b) Multi-index hashing with four 16-bit substrings; exact.
- (a) pHash from the stored thumbprint via DCT.
- Gain: gate 172 → 0.47 µs per pair, results build 2-6x (M4). MIH is 2.2x at r=10 and 15-40x only at r≤7. pHash adds at most 0.6 pt of textured recall.
- Effort: c S/M, b S, a S/M.
- Risks: pHash is worse than dHash on flat images and needs a flat guard. r≤7 requires pHash, so the big index win rides the riskiest piece.
- Verdicts: partly feasible; new; I2/E3.
- Measure: vector gates vs `Thumbprint` within 1e-3 (measured 6e-7), MIH equal to brute force for r 4-10, Release timing at 10k/50k/100k.

#### P13 Copy router and exact tiers
Router first: a pair gate in `DuplicateGrouping.group` sends a confirmed match to Duplicates only if timestamps are equal, dimensions differ, or dt exceeds 120 s. Otherwise it goes to Similar, with the sharpest keeper. It needs only metadata. Block on aspect bucket, not exact `(width, height)`, which gave recall 0.125 on the synthetic set. Skip the 64 KB prefix tier. Instead fold SHA-256 into `SizeMeasurer`'s existing full read for an "identical file" label. Video keyframes only for pairs that pass the poster hash and duration. **Not in the free app since 2026-10-18:** the free app does not analyze videos, so it has no video keyframes or poster hashes; video analysis is a one-time $2 Pro feature, not built yet (see specs/004-phased-cleaning/spec.md FR-004a).
- Gain (simulated): all 100 removable burst frames land in Similar (was 57). Strict Duplicates precision goes 73% → 100%. All 144 true-copy pairs are unchanged.
- Effort: router S, digest S/M, video M (not in the app).
- Risks: same-dimension copies within 120 s are untested; hashing adds I/O; `dataSize` is iOS 27 only.
- Verdicts: partly feasible; new (aspect and `hasAdjustments` gates exist); I3/E4.
- Measure: strict precision with burst frames counted wrong, burst-in-Similar assertion raised from 50% to 95%, new 5/30/100 s same-size copy fixtures.

#### P07 Edited copies (descoped)
Keep two survivors: raw vectors via P08, and a filter-only "edited copies" category. The category uses dHash ≤10, high-pass detail correlation and an aspect match. It runs after Duplicates and Similar, unselected, at lower confidence. Drop IVF, SQ8 and homography. Feature prints are not filter-invariant (medians 0.20-0.58 vs a 0.05 radius). Homography confidence was always 1.0 and passed 23-55% of true crops. Brute-force sgemm over 10k costs about 0.33 s.
- Gain: recovers instant-filter copies 40/44 and tone shifts 16/23; crops stay unfindable.
- Effort: L as written, about one week descoped.
- Risks: needs an FR-002 amendment. Mild-filter re-imports already group as preselected Duplicates. Pearson ≥0.9 alone reaches 0.926 on distinct photos.
- Verdicts: partly feasible; new; I2/E4.
- Measure: per-transform tagged real copies, at least 90% precision on 200 hand-labelled pairs before any UI.

### Phased (time-blocked) matching

#### P14 Group shaping, then sessions
Ship shaping first on the existing 60 s window. After union-find (`SimilarShotsDetector.swift:32-50`), run a `GroupShaper`.
- Split at the largest gaps and split off members far from the medoid.
- Cap groups at 12, exempting burstID groups.
- Demote long uniform sequences through a per-group `preselects` flag.
- Apply the same medoid guard to Duplicate groups of 3 or more.

Then, behind real labels, add a `Sessionizer`: 10 min gap, about 1 km bucket, window clamp(6x median gap, 60 s, 10 min), neighbour cap 40.
- Gain: removes the chain group that preselects hundreds of removals. Bounds a 500-frame minute (125k → ≤20k pair tests). Sessions add retakes 1-10 min apart (an unmeasured estimate of +3-10 pp).
- Effort: M; shaping alone S/M.
- Risks: the 1% aspect gate drops mixed-orientation retakes. Wider windows add same-place links to a preselected category. `Confidence.lower` is wired to the iCloud badge. Don't persist location buckets.
- Verdicts: feasible; partly exists (window and burst union); I3/E3.
- Measure: fixtures for 0/50/130/200 s retakes, a 40-frame walk, a 500-frame minute and same-room negatives, with an A/B behind a flag.

#### P02 Candidate-driven staged analysis
Lite first.
- Compute sharpness before aesthetics and run aesthetics inline only below the blur threshold. Don't defer it: `BlurDetector` treats nil as flagged, so deferral over-flags Blurry.
- Skip feature prints for screenshots and videos (the app does not analyze videos at all since 2026-10-18, and there is no paid version with video analysis, 016).
- Run face quality lazily in a `GroupEnricher` (modelled on `SizeMeasurer`), only for similar-group members in the 0.02 tie band.

Full, behind real calibration: an `AnalysisStages` mask and feature prints only for ambiguous pairs, with reject-only thumbprint bands (t<0.25). Don't adopt the t≥0.80 no-print accept: it removes the guard that exists because layout correlation matched different photos.
- Gain: lite captures about 540 of about 610 s of modelled Vision time. The cascade nets about 70 s minus 3-5k preview re-fetches. Expect 1.5-3x if Vision-bound, about 1x if PhotoKit-bound.
- Effort: lite S/M, full M/L.
- Risks: keepers change after enrichment (patch in place; `AppModel.apply` resets selection). It needs a persisted phase, an optional featurePrint in `LibraryItemRecord.item`, and P08.
- Verdicts: feasible; new (only a comment at `Analyzer.swift:24`); I4/E4.
- Measure: signposts first. If Vision is under 40% of item time, ship lite only. `[.cheap]` vs `[.all]` must give identical groups and keepers. Count Vision calls (about 4-6k vs about 30k).

### Systems and evaluation

#### P15 Scan governor
Minimal version: replace the binary `isTooHot` (`ScanPipeline.swift:438-441`) with a pure policy table, re-read per completed item.
- `.serious` runs 1-wide at `.utility`; `.critical` pauses.
- Low Power Mode and background-continued run 2-wide; `.fair` stays at 4.
- Surface `isThrottled` in `ScanProgress`.
- Guard memory with `os_proc_available_memory()` under `#if os(iOS)`.

Chunk-boundary stalls (about 313 per 10k scan, each draining the group) need cross-chunk pipelining, not the old 100-item flush swap.
- Gain: scans keep moving under heat and in the background. Boundary stalls are an estimated 3-8% of wall time.
- Effort: minimal S/M, pipelining M.
- Risks: contradicts specs 001/002 and `thermalPauseWaitsUntilCool`. Continuous 1-wide load may pin `.serious` worse than pause-and-cool. An async checkpoint interacts with crash reclaim.
- Verdicts: partly feasible; thermal injection and pause plumbing exist; I2/E3.
- Measure: skip if `.serious` is under 5% of a scan. Sweep width 1-6. 2-wide must hold at least 85% of 4-wide before `.fair` changes.

#### P16 Measurement and evaluation harness
1. CI runs `swift test -c release -Xswiftc -enable-testing` including accuracy (29 s vs 5:52 in Debug). Delete the broken `ZZ*Tests.swift` files.
2. `OSSignposter` plus a `ScanMetrics` actor around preview fetch, each analyze stage, chunk lease/fetch/checkpoint, plan and results build. It writes a JSON report with delivered preview size, `phys_footprint`, thermal timeline and items/s.
3. An optimised `-Benchmark N` path (not `#if DEBUG`, which reads about 60x pessimistic), with a random sample and two passes on one store.
4. Scale guards with comparison counters.
5. Later: Core Image/ImageIO variants, `-ExportSignals`, a calibration sweep.
- Gain: no speed-up. It answers the PhotoKit vs Vision share, the `.fast` delivered size, repeat-scan time and peak memory.
- Effort: slices 1-2 S, 3 M, all L.
- Risks: an iPhone 17 Pro understates iPhone 12 heat. Tens of real labels give ±10 pt intervals; certifying 98% needs about 150 pairs with zero misses. Keep exports local.
- Verdicts: feasible; new (only `-TraceScan` logging); I4/E4.
- Measure: one command reproduces the device report, and a scale guard fails on an injected O(n²) loop.

> **Update 2026-10-18.** Building results off the main thread (the first half of P10) is done
> and was urgent: with a real scanned library the build exceeded iOS's 10-second launch
> limit and the app could not start on the author's phone. The build itself is still
> expensive CPU work at every launch (P12 duplicate kernel, P10 snapshot).

## 3. Ranked roadmap

| Rank | Proposal | Direction | Impact | Effort | Depends on |
|---|---|---|---|---|---|
| 1 | P16 slices 1-3 | systems | 4 | 4 (first slices 2) | none |
| 2 | P13 router, SHA label | matching | 3 | 4 (router 1-2) | none |
| 3 | P08 slice A | caching | 2 | 3 (slice 2) | none |
| 4 | P01 fused pass, gates | local ML | 3 | 3 | P08 |
| 5 | P02 lite, then full | phased | 4 | 4 | P08, P01, P16 |
| 6 | P12 cascade, then MIH | matching | 2 | 3 | none |
| 7 | P10 off-main, snapshot | caching | 3 | 3 | P08 |
| 8 | P14 shaping, sessions | phased | 3 | 3 | P12 (cost) |
| 9 | P05 pick keeper | local ML | 3 | 4 | P02 (stage skip) |
| 10 | P15 minimal governor | systems | 2 | 3 | P16 |
| 11 | P09 handles, `.exact` A/B | caching | 2 | 3 | P16 |
| 12 | P11 tokens, match graph | caching | 3 | 5 | P08; P14 for graph |
| 13 | P04 flags | local ML | 2 | 3 | P08 (backfill) |
| 14 | P06 learned head | local ML | 3 | 4 | real labels, P08, P16 |
| 15 | P07 edited copies | matching | 2 | 4 | P08, FR-002 |
| 16 | P03 subject blur | local ML | 2 | 3 | real labels |

**Quick wins (do first)**
- P16 slices 1-2: release CI, remove `ZZ*` files, signposts, one device report.
- P13 router pair gate.
- P08 slice A.
- P12 vector cascade with the similar-pass reorder.
- P10 off-main build.
- P14 group shaping.
- P09 chunk-scoped handles.
- P04 flags.

**Next**
- P01 and P02-lite, right after P08A.
- P05 pick keeper.
- P15 minimal governor.
- P11 change tokens.
- P10 snapshot and slim items.
- P12 MIH.
- P14 sessionizer.
- P09 `.exact` A/B.
- P13 SHA-256 label.
- P16 variants and calibration.

**Big bets**
- P02 full cascade.
- P06 learned head.
- P11 match graph.
- P05 landmarks kernel.
- P07 edited copies.
- P12 pHash.
- P13 video keyframes (not in the app since 2026-10-18).
- P03.

Measurement comes first because every per-stage cost above is an estimate, and the Mac numbers say Vision and PhotoKit, not pixel loops, dominate. Phased matching changes which signals are needed. Similar matching is already blocked by a 60 s window, so a photo with no neighbour in its window never needs a feature print, face score or aesthetics score. In the modelled library that is about 3,000 of 10,000 photos (an assumption, not a measurement). Duplicates stay time-agnostic, so only metadata and hash blocking apply there. Staging (P02) therefore beats squeezing every Vision call (P01). P01 ships only its cheap parts: the fused handler, kind gates and the luma plane. Wider sessions (P14) enlarge the set needing prints, so key the skip set on the 60 s floor and ship shaping before widening. Exact, no-schema wins go first because they force no re-analysis. The version stamp lands before anything that changes fingerprints, so users pay one rescan.

## 4. Dropped, not in the app, or already done

- IVF index and SQ8 (P07): brute-force sgemm takes about 0.33 s at 10k, and SQ8 error is about 10% of a 0.05 radius.
- Feature-print radius for filtered or cropped copies (P07): not invariant, with medians of 0.20-0.58.
- Homography crop confirmation (P07): confidence was always 1.0 and the inputs must be the same size.
- Neural Engine pinning (P01): zero measured gain and a launch-abort hazard.
- vImage/vDSP rewrite of `BlurEffect` (P01): the scalar loop auto-vectorises and vImage was 4x slower.
- The t≥0.80 accept-without-print shortcut (P02): it removes the feature-print agreement guard.
- Exact `(width, height)` and `dataSize` perceptual blocking (P13): recall 0.125.
- The 64 KB prefix-hash tier (P13): near-zero recall gain for real I/O.
- Duplicate-video confirmation by poster hash and keyframes (P13): not in the app since 2026-10-18, which does not analyze videos, and there is no paid version with video analysis (see specs/004-phased-cleaning/spec.md FR-004a and specs/016-free-photos-only/spec.md).
- A hard `isUtility` exclusion and the document-segmentation section (P04): blur-recall risk, with the gate firing on 20-35% of photos.
- Saliency-crop blur and an independent smudge rule (P03): deferred; see above.
- The hot/cold record split and `propertiesToFetch` (P08 slice B): the gain is only 1.2-1.8x, and faulting is slower.
- The Core ML runtime for the learned head (P06): vDSP weights are over 100x cheaper.
- A persisted per-asset session key or location bucket (P14): sensitive, and sessions recompute in milliseconds.
- Per-edge SwiftData rows (P11): 325 µs per write.
- `.fair` half-width, the memory-pressure dispatch source and notification bridging (P15): replaced by per-item reads and `os_proc_available_memory()`.
- Already done: the 60 s window, burstID union, hash multi-index, `hasAdjustments` and aspect gates, the full-scan notScanned retry, `Sendable` detectors, stable group IDs and the network-off options factory.

## 5. Open questions for you

1. Is one forced full re-analysis on upgrade acceptable (it breaks the 30 s repeat target once), given that P01 and P08 change fingerprints?
2. Which spec changes do you accept?
   - FR-002: allow a non-preselected edited-copies category.
   - FR-008: use the burst pick as keeper.
   - The 001/002 thermal rule: slow to 1-wide instead of pausing.
3. Should near-identical burst frames go to Similar (sharpest keeper) rather than Duplicates (largest or oldest), and should Similar stay preselected?
4. Will you label about 300 real photos locally (at least 100 blurry, 40 hard negatives, 150 duplicate pairs including messenger re-saves)? P03, P06, P12 pHash and P04's section wait on this.
5. For SC-001, do you want to project iPhone 17 Pro numbers by an assumed factor, or borrow an iPhone 12-class phone?
6. May session splitting use a roughly 1 km location bucket, computed at results time and never stored?
7. Is iOS 27-only code (`dataSize`, the change observer) worth carrying when your phone runs iOS 26?

---

## Critic review: gaps

- UNDER-SERVED DIRECTION: local ML. The only early-shipping 'ML' items are P01 (re-plumbs Vision calls it already makes) and the P04/P05 metadata flags. The real ML items are all deferred or ranked low: P03 deferred, P06 rank 14, P05 landmark kernel and P07 in 'Big bets'. All of them wait on the 300-photo labelling ask (Open question 4). No proposal applies learned models to the matching side. Duplicate and similar decisions stay hand-set (dHash<=10 bits, detail>=0.85, MAD<=11, t>=0.5, fp<0.1/0.15). The doc also never harvests labels from the user's own on-device behaviour (deselecting a suggestion, 'always keep' marks, confirmed removals), which is the only label source that scales without asking for 300 photos. It also skips Vision's built-in classifier outputs as cheap gates.
- BLUR: a verified defect and the standard remedies are missing. The P06 probe found the featureless-contrast guard returns 'sharp' for 64 of 138 heavy blurs (Sharpness.swift guard at contrast<12). No quick win fixes it; the cheapest fix (a guard or refit on stored scalars) is buried inside P06 at rank 14. Never considered: a tile-percentile sharpness map (top-k tile or p90 of a 3x3 or 4x4 grid), which research R5's original decision had and which was dropped without a replacement. Also never considered: gradient-anisotropy or directional blur (motion vs defocus), the FFT high-frequency energy ratio, and classic no-reference IQA (BRISQUE/NIQE-style). P03's saliency crop failed its probes (45-76% frame coverage, crops scoring blurry photos 0.61-0.63), so the whole 'subject-aware blur' goal is left with no working path. The 85% recall target is certified only by synthetic 100%/0%.
- STANDARD MATCHING TECHNIQUES NEVER NAMED. (a) Single-linkage union-find chaining is patched with a bespoke GroupShaper (medoid, cap 12, demotion), when the standard fix is average- or complete-linkage agglomerative clustering with a cut distance, DBSCAN/HDBSCAN, or correlation clustering. (b) Shift and registration tolerance: dHash and the 32x32 thumbprint are shift-sensitive (the P12 verification shows 1 px shake giving SSIM 0.655-0.988, overlapping true copies). Phase correlation via a vDSP FFT, or a small-shift NCC search, is the usual cheap fix, and it replaces the Vision homography that was dropped because its confidence is always 1.0. (c) Every pixel signal is grayscale, with no chroma thumbprint or HSV histogram intersection, even though P02 and P12 both flag same-layout different-scene false matches. (d) The only alternative hash considered is DCT pHash. Blockhash, Marr-Hildreth and radial-variance (RASH) hashes are not. (e) No copy-detection descriptor (SSCD-style metric-learned embedding) is considered, although P07 shows Vision revision2 prints are not filter or crop invariant (medians 0.20-0.58 vs a 0.05 radius). (f) HNSW and LSH are not named, only IVF/SQ8, which was rightly dropped at 10k.
- PHOTOS-LIBRARY ASSUMPTIONS UNADDRESSED. (1) Live Photos: the doc never says which resource is analysed (key still vs paired-video poster) or how a Live Photo and its exported still route in P13. (2) Cross-source fingerprints: .cloudPreview items are analysed from roughly 256-300 px thumbnails and local items from 512 px, so dHash, thumbprint and sharpness are not comparable across sources. Duplicate and similar pairs mixing a cloud item with a local one are untested, and an item whose original arrives (P11 upgrade) has its stored fingerprints replaced. (3) Messaging re-saves: WhatsApp and similar apps resize, strip EXIF and usually set a new creation date. The timestamp-based tiers (P13 'equal timestamps', P14 windows) cannot help them, and no fixture models this (synthetic copies are only resized and JPEG-recompressed). (4) HEIC to JPEG, Display P3 to sRGB and HDR gain-map re-saves shift luminance, which stresses the MAD<=11 and brightness gates. (5) Edited assets: for hasAdjustments assets, the original resource is shared by differently edited assets, so an 'identical file' SHA label over the original is wrong. (6) Burst frames, Live Photo stills and ProRAW/RAW+JPEG resources can share a capture second, so an equal-timestamp router rule needs a burstID or sub-second guard. (7) Shared Library, hidden assets and Limited access behaviour under the delta path appear only inside the P11 caveats.
- CACHING: no re-derivable pixel tier, so upgrades force a rescan. Open question 1 accepts one forced full re-analysis (roughly a 10-minute rescan, breaking the 30 s repeat target) because P01, P08 and P12 change fingerprints. Every caching proposal caches results or metadata (feature prints, snapshots, change tokens, edges). None retains a tiny derived raster (for example 64x64 or 128x128 luma plus 16x16 chroma, about 4-16 KB per item, 40-160 MB at 10k) from which dHash, pHash, the thumbprint, edge statistics and the P12 vectors could be re-derived without PhotoKit. Pair verdicts are cached only in P11's large Slice B. The feature-print raw vector is cached, but nothing covers Vision revision drift across OS updates beyond a stamp that triggers the same full rescan.
- HARD-CONSTRAINT AUDIT IS INCOMPLETE. The task constraint says only previews of 512 px or less that are already on the phone are analysed. P13 hashes full original resource bytes (SHA-256 over PHAssetResourceManager data) and decodes keyframes from locally stored video originals with AVAssetImageGenerator (since 2026-10-18 the free app does not analyze videos, so the keyframe part of P13 is not in it). The doc presents this as a plain 'identical file' label. The only precedent is SizeMeasurer, which counts bytes and discards them. Spec 002 FR-014 says 'previews only' and research R6 rejected multi-frame sampling for this reason. Open question 2 lists FR-002, FR-008 and the thermal rule but not this one. Persisted-artifact rules are also incomplete. The doc adds a location bucket (Q6), but does not say whether the P11 album map, P16 signal exports (hashes, thumbprints, feature prints) or any retained raster tier are covered by Settings delete-all-data and export.

## Critic review: extra ideas not in the proposals

- **Implicit local labels plus a tiny learned pair verifier and calibrator**: Keep marks, deselected suggestions and confirmed removals are free, on-device ground truth. They can calibrate duplicate and similar thresholds and train a small logistic or GBDT model over cheap pair features (dHash bits, thumbprint NCC, MAD, fp distance, dt, aspect). That unblocks the real-label dependency of P03, P04, P06 and P12 without any network or telemetry.
- **Retained 64x64 luma and 16x16 chroma raster (derived cache) for lazy re-derivation**: Re-deriving dHash, pHash, thumbprint and edge statistics from stored pixels lets a version bump migrate in the background in seconds instead of re-fetching and re-analysing every preview. It also gives a chroma signal for same-layout false matches. Cost is about 40 MB per 10k items, local and file-protected like the existing store.
- **Phase correlation or small-shift NCC as a shift-tolerant verifier (vDSP FFT)**: It is the standard cheap registration method for handheld and burst frames and mild crops. It fixes dHash and thumbprint misses on 1-2 px shifts and replaces the Vision homography that was refuted (confidence always 1.0). It runs on 32x32 to 64x64 data in microseconds.
- **Average-linkage or DBSCAN clustering over the feature-print and thumbprint graph instead of single-linkage union-find plus ad hoc shaping**: This is the textbook cure for chain groups that preselect hundreds of removals. It gives hierarchical cuts that double as session-like blocks, and it can be run per time block with the same pair predicates.
- **Tile-percentile sharpness map with directional anisotropy**: Taking a high percentile of per-tile Crete-Roffet scores is a cheap, deterministic stand-in for the failed saliency crop (it rescues sharp-subject-on-bokeh photos). Gradient anisotropy separates motion blur from defocus and supplies the reason label that P03 wanted. Both are scalar-loop work with no extra Vision calls.

## Critic review: claims not backed by the verification data

- 'The Mac numbers say Vision and PhotoKit, not pixel loops, dominate': every prototype used in-memory CGImages, so no PhotoKit timing exists anywhere. The P09 and P16 verifiers call the PhotoKit share unknown. Only 'Vision plus ANE dominate the CPU path on an M4 Max' is measured.
- P12 '172 us per pair' and 'gate 172 -> 0.47 us, results build 2-6x': the P12 value benchmark measured the same gate at 28-32 us per pair and Thumbprint.similarity at 8.6 us. The P14 benchmark measured 38 us per pair. The 2-6x results-build gain comes from a synthetic event model.
- P02 'lite captures about 540 of about 610 s of modelled Vision time': the faces ~400 s, aesthetics ~200 s and prints ~100 s split is self-declared. The M4 per-call costs measured under P01 are roughly equal (3.4-4.3 ms each) on fixtures with no faces. The P02 verifier says the speed case rests on unmeasured per-inference estimates and 'expect 1.5-3x if Vision-bound, about 1x if PhotoKit-bound'. 'Staging (P02) therefore beats squeezing every Vision call (P01)' is argued on that model, while P01's 40% is the only measured Vision saving.
- 'A photo with no neighbour in its window never needs a feature print, face score or aesthetics score': BlurDetector reads aesthetics for any photo below the sharpness threshold, neighbours or not (the doc's own P02 lite step says so). The 3,000-of-10,000 figure is an admitted assumption. The P02 verifier expects 60-80% of window members to need prints. The P14 verifier says wider windows shrink the skippable set by a third to half.
- P01 'copy dHash flips drop from 3.2 to 0.4 bits' and '~40% less compute': measured on 40 synthetic random-rectangle scenes (resize 0.5, JPEG q0.3) on an M4 Max. The P12 verification states synthetic scenes cannot discriminate hash variants. The verifier estimates first-scan wall time at 10-30% if Vision-bound and about 0% if PhotoKit-bound. ANE contention at 4-wide on an A14 is untested.
- P06 'estimated +3-10 pp recall at 10% false flags': the verifier calls it a guess, not measured. The 0.91 recall and 0.05 false-positive result uses 125 synthetic labels. The AUC 0.99 probe used 59 wallpaper scenes with synthetic Gaussian blur. The 64-of-138 featureless-guard defect is from synthetic sigma-5 blur, so real-photo incidence is unknown.
- P08 'relationship faulting is 3-10x slower' and 'B's diff only 1.2-1.8x faster': another benchmark in the same proposal (loaded Mac) reports 10-20x (4.5-13 s per 10k) and a 15-40% blob-removal gain. The best-case hot-row fetch was about equal to today's full fetch. 'vDSP_distancesq reproduces Vision distance exactly' is verified on macOS 26 only, not on an iOS 18 or 26 device.
- P09 'realistically 5-12% of a first scan': an estimate with no on-device profile. PHAsset refetch cost (0.3-3 ms), 'resizeMode .fast delivers about 1008 px' and the look-ahead overlap ceiling are all unmeasured. The header says only 'may be larger', and caching preheats only image sources.
- P10 'first paint about 0.15 s vs 2-6 s' and 'resident results 54 MB -> under 2 MB': the A14 factor (about 2.4x) is assumed, and the clustered-hash stress inputs are invented. Only the M4 decode (40-51 ms) is measured. The snapshot is invalidated by any library change, so the warm-start hit rate for active libraries is unknown. The resident-size claim has no measurement.
- P11 'zero-change foreground drops from an estimated 0.5-3 s to one token query', 'B makes results independent of library size' and 'edges 4-6k': none is measured. Headers do not say that album-membership changes surface as updated assetCollection changes. Headers do not say how persistent changes behave under Limited access. Immutability of unedited originals is unverified. The P11 verifier thinks the favorite/album-bump re-analysis saving is probably overstated.
- P04 'the gate would fire on 20-35% of photos' and 'accidental pocket shots look utility-like': isUtility rates are unpublished and unmeasured. These are stated as fact in the doc but are estimates ('plausibly 15-35%').
- P05 'keeper matches the camera or user pick (SC-007)': SC-007 has no test or harness. There is no evidence that Apple's autoPick or userPick beats the current sharpest-frame heuristic. Imported bursts report .none, and some bursts have no representative frame.
- P07 'recovers instant-filter copies 40/44 and tone shifts 16/23': measured with plain Pearson>=0.9 plus dHash<=10 plus aspect. The doc says the category will use high-pass detail correlation, and the verifier shows Pearson alone is weak (distinct photos reach 0.926). The corpus is 53 Apple template and wallpaper images, not phone photos. 'Brute-force sgemm about 0.33 s at 10k' conflicts with 0.09 s elsewhere in the same verification, and the device figure is an estimate.
- P12 'pHash adds at most 0.6 pt of textured recall' is 1 of 160 pairs on 42 wallpaper tiles from 7 images, so it is statistically empty. Flat images were measured as worse under pHash than dHash. MIH exactness was tested on random and near-seed hash sets only.
- P13 simulated gains (100 removable burst frames to Similar, strict precision 73% -> 100%): synthetic copies sit at least 5,400 s apart, so same-dimension copies within 120 s are untested. The 73% counts burst frames in Duplicates as errors, though the current composition test accepts Duplicates or Similar. The router sends 60-120 s same-dimension pairs to Similar, but Similar's window is 60 s, so they are unreachable unless Similar consumes the confirmed edges. The 'equal timestamps' rule collides with burst and Live Photo frames at second resolution. The 'identical file' label is not safe for hasAdjustments assets.
- P14 'removes the chain group that preselects hundreds of removals': no real-library evidence of how often such chains occur. '+3-10 pp retakes' is an admitted estimate. The medoid guard on Duplicate groups of 3 or more is called low-risk, but DuplicateAccuracyTests matches 40 groups exactly, so one split gives 39/40 = 97.5%, below the 98% target. The doc's risk list omits this.
- P15 'boundary stalls are an estimated 3-8% of wall time': the P15 verifier's own guess is 8-13%, and neither is measured. Whether 1-wide at .utility beats pause-and-cool under .serious is untested, and QoS may not reach PhotoKit or ANE work.
- Roadmap ranks: the impact numbers (I/E verdicts) are whole-proposal scores, while several effort figures are for slices (P13 'router 1-2', P08 slice A, P16 slices 1-3). No common benefit unit is used, and every iPhone 12 figure is an extrapolation from an M4 Max under an assumed 2-3x factor (the verifier notes the user's phone is an iPhone 17 Pro, which understates thermal and energy cost).
