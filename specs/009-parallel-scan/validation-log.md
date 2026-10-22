# Validation log: a scan that uses the whole Mac

Run on 2026-10-21 on the author's Mac (Apple M4 Max, 14 cores: 10 performance, 4 efficiency; 36 GB),
release builds, the real `DefaultAnalyzer` (Vision on the Neural Engine) throughout. Nothing here ran on
a phone. Tools:

```
swift run -c release --package-path Packages/CleanupKit/Benchmarks/ScaleBench ScaleBench \
    --real-scan --count 30000 --demo --latency-ms 15 --profile mac      # or --profile phone, --concurrency N --lanes N ...
ScaleBench --analyzer-scaling | --vision-probe | --results-profile <kept store> | --bucket-stats <store> | --what-if-defer-vision
```

`--demo` is the app's own `-DemoScenario large30k` library, regenerated call for call; its results
(772 duplicate groups / 2,213 photos, 4,441 similar / 12,012, 1,232 blurry, 1,386 screenshots, 50 large
videos) are those of the 008 log. `--latency-ms 15` is `-DemoAnalysisLatencyMs 15`. Without `--demo` the
bench draws 512 × 384 pictures (the size a phone's preview request asks for) from its own generator.
"Before" is the unchanged code at `18e39a3`, built in a second worktree with the same benchmark files.

Caveat on noise: the machine was not otherwise idle. Another session ran simulator UI tests until 15:48
and system daemons (`photolibraryd`, `suggestd`, `maild`) used one to two cores throughout. The 3,000-item
runs agree to 0.1 s between repeats; the 30,000-item runs were taken once, the "before" ones earlier in the
afternoon. The "before" 30,000 run reproduces the 3 min 51 s seen in the app (230 s here, 217 s on the demo library).

## Where the time went (before)

`ScaleBench --analyzer-scaling`: 600 analyses over 240 distinct 512 × 384 images.

| Width | Photos a second: CPU math (dHash, miniature, sharpness) | Feature print (Vision) | Face quality (Vision) | Whole `DefaultAnalyzer` | Cores busy (whole) |
|------:|------:|------:|------:|------:|------:|
| 1 | 278 | 337 | 338 | **96** | 0.6 |
| 2 | 531 | 436 | 495 | 189 | 1.3 |
| 4 | 1,007 | 436 | 491 | **320** | 2.1 |
| 8 | 1,867 | 438 | 484 | 328 | 2.1 |
| 14 | 2,243 | 433 | 484 | 329 | 2.2 |
| 28 | 2,273 | 436 | 490 | 324 | 2.1 |

Reading: the math scales 8× and is never the limit; each Vision request saturates at width 2; the whole
analyzer stops at 328 photos a second from width 4. For the 25,500 photos in a 30,000-item library that
is 77 s however wide the scan is. The scan at the app's width of 4 and 15 ms a preview reached 130 items
a second because it waits at every chunk end (below).

`ScaleBench --vision-probe`, feature print and face quality by device (legacy `VNRequest` API, which can
set a device; the Swift `GenerateImageFeaturePrintRequest.supportedComputeStageDevices` is not in the
macOS 26 runtime):

| Device | Feature print | Same bytes as today's? | Face quality |
|--------|---------------|------------------------|--------------|
| framework's choice | 430/s at width 8 | yes, 60 of 60 | 491/s |
| ANE (pinned) | 436/s | yes, 60 of 60 | 465/s |
| GPU | 130/s | no: largest element difference 8.1e-3 | 221/s |
| CPU | 35/s | no: 5.5e-3 | 71/s |
| both requests on one handler | 215 photos/s at width 4 (144 at 8) | | |
| two processes at once | 281 + 281 = 562/s, against 435 for one | | |

Vision already uses the Neural Engine; the GPU is slower and numerically different, so it is not used (spec Decision 1).

Hash buckets of the 27,690 photos of the demo library: 274 million pairs share a bucket, of which 9.8
million are within the 10-bit distance; the largest bucket has 13,298 photos (`--bucket-stats`).

## Before and after: the scan

Preview latency 15 ms, release build, 14 cores. Mac profile = 14 photos in flight, 4 lanes, chunks of
32, write-behind 24. Phone profile = 4 photos, 1 lane, write-behind 0 (the code path of 008).

**The app's own library (`--demo`, 3,000 and 30,000 items):**

| Case | Before (unchanged code, width 4) | After, Mac profile | Speed-up |
|------|------------------|--------------------|---------|
| Scan, 3,000 items | 23.4 s (128 items/s) | **8.2 s** (366/s; three runs 8.2, 8.2, 8.2) | 2.9× |
| Scan, 30,000 items | 217.5 s (138/s) | **80.7 s** (372/s) | 2.7× |
| Results build after the scan, 30,000 items (cold, in the same process) | 7.10 s | 1.60 s | 4.4× |
| Results digest / stored-analysis digest | `fa169c4d97929604` / `b99703de218f60a6` | `fa169c4d97929604` / `b99703de218f60a6` | identical |
| Peak footprint of the scan (`phys_footprint`) | 227 MB | 241 MB | |
| Peak during the results build | 322 MB | 381 MB | |

**The bench's own 512 × 384 library (3,000 and 30,000 items):**

| Case | Before | After, Mac profile | Speed-up |
|------|--------|--------------------|---------|
| Scan, 3,000 items | 24.3 s (123/s) | **8.2 s** (365/s; three runs 8.3, 8.2, 8.2) | 3.0× |
| Scan, 30,000 items | 229.9 s (130/s) | **80.7 s** (372/s) | 2.8× |
| Results build after the scan | 4.72 s | 1.26 s | 3.7× |
| Results digest / stored-analysis digest | `30b0ab850af1d956` / `bf7161cea2f5ee27` (and `ff1b1f055adec6e7` / `d8c7095364a96205` at 3,000) | the same, all four | identical |
| Peak footprint of the scan / of the results build | 237 MB / 354 MB | 253 MB / 491 MB | |

The Neural Engine's own limit for this library is 77–78 s (25,500 photos at 328 a second); the scan is
within 5% of it. The same 30,000-item run on the old code with only the width raised to 14 (one chunk at a time, no
write-behind) took 162 s (185 items/s): width alone gets about a quarter of the way, because every
chunk waits for its slowest photo and then for the store before the next one starts.

**Width, lanes and chunk size at 3,000 items** (bench library, 15 ms, write-behind 24; one run each, so
differences under about 0.5 s are noise):

| Setting | Scan |
|---------|------|
| 8 wide, 1 lane | 13.0 s |
| 8 wide, 2 lanes | 11.4 s |
| 12 wide, 3 lanes | 8.9 s |
| 14 wide, 2 lanes | 9.5 s |
| 14 wide, 3 lanes | 8.7–10.5 s |
| **14 wide, 4 lanes** | **8.2 s** |
| 20 wide, 4 lanes | 8.1 s |
| 14 wide, 3 lanes, chunks of 64 | 8.6 s |
| 14 wide, 3 lanes, chunks of 16 | 8.9 s |

**The phone profile on the Mac** (width 4, 1 lane, no write-behind), to show the iPhone settings are
unchanged: 3,000 items 23.4 s and 23.7 s (before 23.4 s); 30,000 items 227.8 s (before 217.5 s; within the noise of this machine, where another session started builds during that run), peak 229 MB (227 MB). The settings the phone gets are the ones 008 validated; this run only shows that the new loop adds no cost at width 4.

**Pipeline overhead with a fake analyzer** (`ScaleBench` without arguments, 30,000 items, no latency; what
the store and the loop cost when the analyzer costs nothing): scan 7.5 s (7.7 s before); `itemSummaries`
0.63 s (1.90); `itemsWithoutFeaturePrints` 0.78 s (1.98); `resultInputs` 1.12 s (2.73); `buildResults` 0.23 s (0.65).

**What deferring Vision for photos with no neighbour would save** (`--what-if-defer-vision`, not shipped;
results differ by design), demo library, whose bursts make two thirds of its photos neighbours: 61 s at 15 ms
latency and 55 s without, against 81 s and 79 s with every photo's Vision work. A library with a third of its
photos in bursts, as the 004 research found, would save about two thirds of the Vision time.

## Before and after: the results build

`ScaleBench --results-profile <kept store>`, three repeats on stores kept from the 30,000-item scans,
read = `Store.resultInputs()`, build = `DefaultResultsBuilder.buildResults`:

| Store | | Read | Build | Total | Duplicates | Similar | Digest |
|-------|--|-----:|------:|------:|-----------:|--------:|--------|
| Demo library, 27,690 photos, 9.8 million candidate pairs | before | 2.25–2.64 s | 4.36–4.56 s | 6.60–7.21 s | 3.72 s | 0.59 s | `fa169c4d97929604` |
| | **after** | 0.89–1.02 s | 0.66–0.67 s | **1.57–1.68 s** | 0.43 s | 0.18 s | `fa169c4d97929604` |
| Bench library | before | 2.32–2.72 s | 1.58–1.69 s | 3.97–4.41 s | 0.91 s | 0.60 s | `30b0ab850af1d956` |
| | **after** | 0.92–1.04 s | 0.38–0.39 s | **1.31–1.43 s** | 0.15 s | 0.18 s | `30b0ab850af1d956` |

The read stops improving past 4 to 6 threads (one store coordinator: 2.28 s with 1, 1.52 with 2, 0.99 with
4, 0.95 with 6, 1.07 with 8, 1.01 with 14); the duplicate pass is 8.7× faster, the whole build 4.3×. High-pass
images cached per thread were 2.0 s for the duplicates at 1,170 each and 0.56 s at 4,000 each (450 MB);
computed once and shared they are 0.43 s and at most 134 MB.


## Tests and builds

| Check | Result |
|-------|--------|
| `swift test --package-path Packages/CleanupKit` | 292 of 292 (279 that existed, plus the 13 of `ParallelScanTests`). Repeated five times for the scan suites while another session's builds held the machine at a load average of about 50: 63 of 63 each time |
| `ParallelScanTests.aWideScanFindsExactlyWhatANarrowScanFinds` | 240 photos of every kind scanned one at a time and 8 wide with 4 lanes and write-behind: equal dHash, miniature, sharpness, aesthetics, face quality, source, feature-print distance 0, session counters; results equal built with one thread and with 8, from either store |
| Grouping, similar shots, store reads, slabs | parallel = serial for 2, 5 and 14 workers (3,000 look-alikes, 2,400 photos in runs, 3,450 stored items); the slabs report every candidate pair of the serial index once |
| Lanes | counters equal the chunks' done masks at every pause (three pauses, 4 lanes); a pause is acknowledged after the last lane and the write; failed saves lose nothing; a three-chunk crash counts once; width follows heat and Low Power Mode (8 / 6 / 4 in flight) |
| `scripts/check-no-network.sh` | clean |
| iOS Simulator (debug), iOS device (unsigned), macOS debug and macOS release builds | all succeed |
| Simulator UI suite (iPhone 17, iOS 27.1) | 34 of 34 pass (`xcodebuild test`, no parallel testing), including `StagedResultsTests` and `PersistentSessionTests` |

Found and fixed while testing: a pause's release of leased chunks could land after the write that
finished one of them and undo it (counters then ran ahead of the chunk rows). Every write that changes
chunk rows and counters, and the release, now takes turns through `withStoreGate`.

## Not done, not observed

- Previews from a real Mac Photos library. The demo and the bench draw their previews (0.3 to 1 ms of
  CPU each) and sleep 15 ms; the cost of PhotoKit's own decode, `fetchItems` albums lookups and
  `NSImage` to `CGImage` conversion on the Mac is unmeasured. The width and the lanes exist to hide
  such latency, but whether 14 is enough or too many against a real library is not known.
- Anything on a phone, including the heat and memory behaviour of a 30,000-photo scan. The phone profile
  runs the same pipeline with one lane, no write-behind and serial reads and comparisons, which the
  package tests (on the Mac host) and the simulator UI suite exercise; the lanes, the write-behind and the
  parallel build run only where `ScanProfile.current` is the Mac profile, and were exercised by the
  package tests and `ScaleBench` on the Mac.
- The Mac app window (the screen was not available to launch it); `-ScanProfile phone|mac` in a debug
  build selects the profile to compare.
- A pass at 100,000 items.
