# Validation log: Vision work only where a detector reads it

Run on 2026-10-21 on the author's Mac (Apple M4 Max, 14 cores; 36 GB), release builds of `ScaleBench`, the
real `DefaultAnalyzer` (Vision on the Neural Engine) throughout. Nothing here ran on a phone. Tool:

```
swift build -c release --package-path Packages/CleanupKit/Benchmarks/ScaleBench
ScaleBench --real-scan --demo --count 30000 --latency-ms 15 --profile mac            # as shipped: Vision deferred
ScaleBench --real-scan --demo --count 30000 --latency-ms 15 --profile mac --no-defer-vision   # every photo's Vision work, as 009
```

"Complete" below is `--no-defer-vision`: the same code with `deferVision: false`, which plans no skip and no
repair, so it is the scan of spec 009 (`272fa1e`). Its digests are those 009 recorded for that code, which is
how this log shows nothing else changed. The two modes were run one after the other so that the machine's
noise falls on both; the machine was not idle (another session's simulator app used about 1.7 cores,
a virtual machine 1.2, and the load average was 13 to 28 throughout), so single runs differ by several
seconds. `--demo` is the app's own `-DemoScenario large30k` library; without it the bench draws its own pictures.

## Before and after: the scan

Preview latency 15 ms. Mac profile = 14 photos in flight, 4 lanes, chunks of 32, write-behind 24. Phone profile
= 4 photos, 1 lane, no write-behind (the code path of 008), run on this Mac.

| Library | Profile | Complete (before) | Deferred (after) | Saved | Results digest / stored-analysis digest, both modes |
|---------|---------|------------------:|-----------------:|------:|------|
| Demo, 30,000 items | Mac | **86.0 s**, 91.8 s | **68.2 s**, 65.0 s | 21–29% | `fa169c4d97929604` / `b99703de218f60a6` |
| Bench, 30,000 items | Mac | 86.7 s | 68.7 s | 21% | `30b0ab850af1d956` / `bf7161cea2f5ee27` |
| Demo, 3,000 items | Mac | 8.5 s, 8.6 s | 6.7 s, 7.0 s | 19–21% | `19e3839239f3e501` / `a8e314a59efd4e7a` |
| Bench, 3,000 items | Mac | 8.9 s | 6.8 s | 24% | `ff1b1f055adec6e7` / `d8c7095364a96205` |
| Demo, 30,000 items | Phone | 223.1 s (134 items/s) | 203.7 s (147/s) | 9% | `fa169c4d97929604` / `b99703de218f60a6` |
| Demo, 3,000 items | Phone | 22.4 s | 21.6 s | 4% | `19e3839239f3e501` / `a8e314a59efd4e7a` |

- **The results digest and the stored-analysis digest are identical between the two modes in every pair of
  runs**, and equal to the digests 009 recorded for the unchanged code (`fa169c4d97929604`,
  `b99703de218f60a6` for the 30,000-item demo library; `30b0ab850af1d956`, `bf7161cea2f5ee27` for the bench
  library at 30,000; `ff1b1f055adec6e7`, `d8c7095364a96205` for the bench library at 3,000; 009 did not record
  the demo library at 3,000, which is compared across the two modes only). The stored-analysis digest covers dHash,
  miniature, sharpness, aesthetics and face quality; the synthetic previews have no faces, so it does not exercise
  face quality (the package tests do).
- **The same photos are read with a feature print in both modes**: 18,490 of 27,690 analyzed photos in the demo
  library (18,484 in the bench library), the ones with a neighbour within a minute. The deferred scan computed
  no feature print and no face quality for the other **9,200** (demo; 9,206 in the bench library): 33% of the analyzed photos,
  all of them photos no detector reads. (`vision:` line of the bench; it counts prints actually loaded for results.)
- **Why the Mac saves 21–29% and not 33%.** The scan is bound by the Neural Engine only for part of the time; the
  chunk ends, the store and the preview wait still cost, and the CPU math (3.6 ms a photo) is unchanged. The 009
  what-if (61 s against 81 s for the demo library, 25%) is what this reproduces: 65–68 s against 86–92 s.
- **The phone profile saves little on the Mac, and that is expected, not a result for the phone.** With a width of 4
  and 15 ms of preview latency the scan runs at 134 items/s, 41% of what the Neural Engine can serve, so it is bound
  by latency and chunk ends; fewer Vision requests only shorten each photo. The CPU time it took shows the work that
  is gone: **166.7 s → 138.1 s** at 30,000 items (−17%), and 159.3 s → 147.2 s / 139.4 s on the Mac profile. On a phone the Vision requests are a larger share of a photo's cost
  and the scan is not latency-bound the same way; that was not measured (task T041).
- Peak footprint is unchanged: scan 232–234 MB on the demo library and 245–252 MB on the bench library (phone profile 221–223 MB); results build 364–445 MB.

## Results build

Unchanged by this spec except that skipped photos have no print to read. Demo library, 30,000 items, build after the
scan in the same process: 2.54 s complete, 1.93 s / 1.91 s deferred; bench library 1.79 s / 1.60 s (single runs, noise
dominates; the 009 figure was 1.6 s).

## Tests and builds

| Check | Result |
|-------|--------|
| `swift test --package-path Packages/CleanupKit` | 310 of 310 (292 that existed, plus the 18 of `DeferredVisionTests`; `StoreMigrationTests` gained an assertion) |
| `DeferredVisionTests` | The demand rule at its edges (60 s exactly is a neighbour, 60.5 s is not, equal dates, no date, live photos, videos and screenshots are not neighbours, burst only); the plan (skips, repairs in a full scan and a quick check, a changed date or burst with the same modification date, no repair when still not wanted or when nothing was skipped, plans without deferral); chunk masks and item flags through the store; an analyzer that ignores the request is never flagged; a resumed job keeps the plan's decisions with no library listing before the first preview; a chunk run alone after a crash does too; the detector leaves a pair with a skipped print ungrouped; the builder keeps face quality only on similar-shots members |
| Two stages = one shot | `aLibraryScannedInTwoStagesFindsWhatAOneShotScanFinds`, for the phone profile and a Mac-like one (4 lanes, write-behind) and for a full scan and a quick check as the second scan. 38 photos with real Vision at the end (31 in the first batch): solos, a pair exactly 60 s apart and a pair 61 s apart, a burst, bursts far apart in time, a burst alone, a copy an hour later, blurred photos, a photo without a date, a screenshot and a video. The second batch: five photos next to stored photos that have no print (20 s, 59 s, 60 s, 30 s and 10 s away), a photo with a burst id shared with a stored photo, an isolated photo and a screenshot; and in place, with no modification date change, a photo moved next to another and a burst id given to a stored photo; one photo deleted. Asserted: exactly the 7 new photos and the 8 photos made demanding were analyzed (once each, the repaired ones asking for what the library now wants); `CleanupResults.slimmed()` of the two-stage store, of a one-shot deferred scan and of a complete scan are equal; every stored photo's hash, miniature, sharpness and aesthetics equal the complete scan's; every print and face score present equals it (distance < 1e-6); no photo skipped what the final library wants; a photo that lost its neighbour keeps its print |
| Mutation check | With the repair rule disabled the two-stage test fails (wrong photos analyzed, results differ); with the builder's face-quality rule removed it fails on `slimmed()` equality. Both restored |
| Store | A store from before this spec (`Fixtures/previous-store`) opens unchanged and every item reads as "nothing skipped" and is never repaired |
| `scripts/check-no-network.sh` | clean |
| iOS Simulator (debug), iOS device (generic, unsigned), macOS debug, macOS release builds | all succeed |
| Simulator UI suite (iPhone 17 Pro, iOS 26.5, `xcodebuild test`, no parallel testing) | 34 of 34 pass (including `StagedResultsTests`, `PersistentSessionTests`, `BackgroundScanTests`). A first run on a simulator that another session was using at the same moment was stopped and repeated on a free one |

## Not done, not observed

- Anything on a phone: the saving on a phone's Neural Engine, the heat and battery effect, and the scan of a real
  30,000-photo library there (T041). The Mac numbers above are from the Mac profile and, for the phone profile, from a Mac.
- Previews from a real Mac Photos library (T042, as in 009).
- A library where most photos are bursts or most photos are alone: the demo library has two thirds of its photos
  with a neighbour; a library with a third would skip about two thirds of the Vision work, which is the
  estimate this entry started from and was not measured on such a library.
- The cost of a large repair (a bulk import with dates inside a stored photo's minute) beyond the two-stage test.
