# Tasks: Staged Cleanup for Large Libraries

Task numbers of the matching 004 task are in brackets.

## Measure (done)

- [X] T001 `Packages/CleanupKit/Benchmarks/ScaleBench`: release benchmark with a 30,000-item synthetic library, memory by `phys_footprint`, `--stages` (per-photo cost of each analysis step), `--open <store folder>` (results build on an existing store), `--latency-ms` (preview latency) [004 T003]
- [X] T002 `-DemoScenario large30k` / `largeNk` and `-DemoAnalysisLatencyMs` in `DemoPhotoLibrary` [004 T006]
- [X] T003 Spike: lean store readers. `propertiesToFetch` in one fetch did not cap memory (609 MB); a sorted offset page or a keyset page was slow or wrong; unsorted `fetchLimit`/`fetchOffset` slices of 1,000 cap it (94 MB, 1.8 s) [004 T001]

## Scale

- [X] T010 `Store`: `itemSummaries`, `itemsWithoutFeaturePrints`, `featurePrints(for:)`, `refreshMetadata`, `saveSizes` [004 T050]
- [X] T011 `ScanPlanner`: summaries in, metadata-only refreshes out, newest first, quick wins; `ScanPipeline` plan, catch-up and `apply(plan)` use them [004 T013]
- [X] T012 `ResultsLoader` (prints only for photos with a time neighbour) and `DefaultResultsBuilder` keeps listed items only, without fingerprints [004 T050]
- [X] T013 `HashIndex.forEachCandidatePair`, `ThumbprintMatcher` (exact, cached, block-sum bound), `DuplicateGrouping` skips pairs already joined [004 T005]
- [X] T014 `CleanupKit` optimized in debug builds (`Package.swift`)
- [ ] T015 Cap candidate pairs per photo and in total for pathological libraries (004 T004/T005). Not needed for the 30,000-item look-alike set (7 s) but not proven for 100,000; run `ScaleBench --count 100000`

## Stage

- [X] T020 Quick wins stored by the plan; screenshots never opened; aesthetics only where blur reads it [004 T020]
- [X] T021 `ScanBlocks`, `ScanProgress.publishedRevision`, `minProgressInterval` [004 T030]
- [X] T022 `AppModel`: rebuild on revision, hold while a list is open, `ReviewChoices` over every rebuild, pacing, sizes only on demand [004 T031, T032]
- [X] T023 Home, Results, Category: "Found so far · checked N of M", "Looking for things to clean up", "N new results. Show" [004 T033]
- [X] T024 `ScanContinuation` and `MacScanKeepAlive` update the system display and the log at most once a second
- [ ] T025 Per-row "still checking" (004 FR-009 wants it on every row); only the section header says it now
- [ ] T026 Defer feature print and face quality to photos with a neighbour, with the repair rule (Decision 2) [004 T012]

## Test

- [X] T030 `StagedCleanupTests`, `ResultsContinuityTests`, `ThumbprintMatcherTests`
- [X] T031 Whole package suite, `scripts/check-no-network.sh`, iOS simulator and macOS builds
- [X] T032 `large30k` on the Mac: staged results, memory, kill and resume ([validation-log.md](validation-log.md))
- [X] T033 UI tests for staged results (`StagedResultsTests`) on the simulator
- [ ] T034 A 30,000-photo scan on a phone in the background (the cause on iOS is unobserved)
