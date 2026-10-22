# Tasks: A Scan That Uses the Whole Mac

## Measure (done)

- [X] T001 `ScaleBench --analyzer-scaling`: the real `DefaultAnalyzer`, and its parts, over realistic 512×384 images at widths 1, 2, 4, 8, cores, 2×cores (images a second, CPU a photo, cores busy)
- [X] T002 `ScaleBench --real-scan`: a full scan with the real analyzer, then the results build, with a digest of the results and of the stored analysis; `--profile mac|phone`, `--concurrency`, `--lanes`, `--write-behind`, `--chunk`, `--latency-ms`, `--keep <folder>`; `--demo` reproduces the app's `large30k` library photo for photo
- [X] T003 `ScaleBench --vision-probe`: which compute devices Vision's requests may use, throughput and output of each device against the framework's choice, both requests on one handler
- [X] T004 `ScaleBench --results-profile <store>`: read, build and each detector on a kept store; `--bucket-stats` (hash bucket sizes of the candidate pairs)
- [X] T005 `ScaleBench --what-if-defer-vision`: the time of a scan that skips the feature print and face quality of photos with no neighbour (not shipped; 008 Decision 2)

## Scan

- [X] T010 `ScanProfile` (`.phone`, `.mac()`, `.current`, `width(thermal:lowPower:)`)
- [X] T011 `ScanPipeline`: lanes, the writer stage with write-behind and batched commits, per-chunk tallies, a set of leased chunks, the store gate, pause acknowledged by the last lane and the writer
- [X] T012 `ScanReclaim`: one death is one crash however many chunks were running
- [X] T013 `AppEnvironment`: the profile (`-ScanProfile phone|mac` in debug builds); `StandardPipeline.detectors` takes its parallelism from the profile

## Results build

- [X] T020 `SwiftDataStore`: item slices and feature prints read by up to 6 threads, joined in slice order
- [X] T021 `HashIndex` slabs; `DuplicateGrouping.groupInParallel`; `ThumbprintMatcher` with profiles shared between threads (`SharedProfiles`, bounded)
- [X] T022 `SimilarShotsDetector`: feature prints decoded once in parallel, pairs tested in parallel, joined in order

## Test

- [X] T030 `ParallelScanTests`: wide scan = narrow scan (analysis, session, results), grouping and similar shots parallel = serial, store reads parallel = serial, slabs cover every candidate pair once, counters never run ahead with several lanes, pause acknowledged after every lane and the write, failed saves with several lanes, a three-lane crash is one crash, profile shapes
- [X] T031 Whole package suite; iOS simulator, macOS debug and release builds; the simulator UI suite
- [X] T032 Before and after on the Mac at 3,000 and 30,000 items and for the results build ([validation-log.md](validation-log.md))
- [ ] T033 A 30,000-photo scan on a real Mac library through PhotoKit (the previews of the demo and the bench are drawn, not decoded by Photos)
- [ ] T034 The same on a phone: the phone profile is unchanged, but nothing was measured on a phone

## Later

- [ ] T040 Defer feature print and face quality to photos with a neighbour (008 Decision 2, 004 T012). The largest lever left; see Decision 6
- [ ] T041 Faster per-photo math (sharpness is 2 ms of the 3.6 ms), only worthwhile after T040 and only with the same arithmetic in the same order
- [ ] T042 The results read (1.0 s of 1.7 s at 30,000 items) is bound by one store coordinator; a second container on the same file, or a snapshot kept in memory between rebuilds, would remove it
