# Tasks: Vision Work Only Where a Detector Reads It

## Measure (009, done before this entry)

- [X] T001 What the Neural Engine serves and what skipping would save (`ScaleBench --what-if-defer-vision`, 009 [validation-log.md](../009-parallel-scan/validation-log.md))

## Design

- [X] T010 Who reads the feature print and face quality (code, not memory) and the demand rule; the four design questions answered in [spec.md](spec.md)

## Scan

- [X] T020 `VisionWork`; `Analyzer.analyze(_:metadata:vision:)` with a default; `DefaultAnalyzer` skips what it is not asked for; `Analysis.skippedVision`
- [X] T021 `VisionDemand` (sorted dates, two binary searches a photo) and the plan: `ScanPlan.skipVision`, `ScanPlan.repairs`, `deferVision` on `ScanPlanner.plan`
- [X] T022 `ScanChunk.skipPrintMask/skipFaceMask` and the optional `ScanChunkRecord` columns; `ScanPlanner.chunks(skipVision:)`
- [X] T023 `ScanPipeline(deferVision:)`: the plan and the catch-up make the chunks; every analysis path (parallel, lanes, a chunk alone after a crash) asks for the rest
- [X] T024 `LibraryItemRecord.visionSkippedRaw` (optional), `StoredItemSummary.skippedVision`
- [X] T025 `SimilarShotsDetector` leaves a pair with a skipped print ungrouped; `DefaultResultsBuilder` keeps face quality only on similar-shots members and drops the skip record

## Test

- [X] T030 `DeferredVisionTests`: the demand rule at its edges; plans (skips, repairs for a full scan and a quick check, a changed date or burst with the same modification date, no repair when still not wanted, deferVision off); chunks and items through the store; an analyzer that ignores the request; resume without listing the library; a chunk alone after a crash; the detector guard; the builder rule
- [X] T031 A library scanned in two stages (second batch within 60 s of stored photos, a date and a burst changed in place, a photo deleted) equals a one-shot scan of it, deferred and complete: results `slimmed() ==`, per-photo analysis, exactly the new photos and the repaired ones analyzed; phone and Mac-like profiles, full scan and quick check
- [X] T032 `StoreMigrationTests`: a store from before reads as "nothing skipped"
- [X] T033 Mutation checks: no repair, and no builder rule, each fail the two-stage test
- [X] T034 Whole package suite; iOS simulator, macOS debug and release builds; `scripts/check-no-network.sh`

## Measure

- [X] T040 `ScaleBench --real-scan` defers by default and `--no-defer-vision` runs every photo's Vision work; digests, the count of skipped prints, and times before and after on the Mac profile and the phone profile ([validation-log.md](validation-log.md))
- [ ] T041 A 30,000-photo scan on a phone, where the Neural Engine is slower and the saving larger
- [ ] T042 A real Mac library through PhotoKit (as 009 T033)

## Later

- [ ] T050 Photos whose only neighbours are frames of their own burst could skip the print too (Decision 7)
- [ ] T051 Skipping the repair re-analysis of a photo's hash, miniature and sharpness (they come out equal); worth it only if repairs are many
