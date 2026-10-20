# Validation log: staged cleanup for large libraries

What has been run, when (2026-10-20, the author's Mac, an Apple-silicon laptop with 14 cores and
36 GB), and what is still open. Nothing here was run on a phone.

## Benchmarks (`ScaleBench`, release unless noted)

Synthetic library of 30,000 items shaped like the 004 research (9% screenshots, 6% videos, a third of
the photos in bursts, about 4% copies). Preview latency 0. Memory is `phys_footprint`, the number the
system's limits use.

| Case | Before | After |
|------|--------|-------|
| Full scan of an empty store (zero preview latency) | 7.2 s, peak 54 MB | 6.9 s, peak 65 MB |
| Read stored items for a scan plan | `items()` 1.2 s, **644 MB** peak | `itemSummaries()` 1.8 s, **94 MB** peak |
| Read stored items for results | `items()` 1.2 s, 644 MB peak | `itemsWithoutFeaturePrints()` 1.8 s, 123 MB peak; prints for 1,872 photos 0.07 s |
| Results build of 30,000 items, debug build | 84.7 s | 0.68 s |
| Results build on the large demo library's store (27,700 photos, 9.8 million candidate pairs) | **281.5 s**, peak 625 MB | **7.0 s**, peak 312 MB, same result (digest `59195ed6dce40230`; duplicates 772 groups / 2,213 items, similar 4,441 / 12,012, blurry 1,232, screenshots 1,386, videos 50) |
| Per-photo analysis, debug build | 193.6 ms (sharpness 183.6 ms) | 12.8 ms (sharpness 1.9 ms) |
| Chunk boundary overhead at 40 ms per preview, width 4, chunk 32 | 12.7% (33.8 s against an ideal 30 s for 3,000 items) | unchanged (Decision 3) |

Per-photo cost of each analysis step, release, one at a time: dHash 0.7 ms, miniature 0.7, sharpness
2.1, feature print 3.1, aesthetics 3.2, face quality 3.3 (13.3 ms in all).

Two ways to read the stored items that did not work (recorded so they are not tried again): one
`FetchDescriptor` with `propertiesToFetch` and `ModelContext.enumerate(batchSize:)` both peaked above
600 MB, as if the fingerprints were read anyway; sorted offset paging was correct but took 3.3 s, and
keyset paging on the string id returned 2,015 of 30,000 items (the predicate and the sort do not compare
strings alike).

## macOS app, `-DemoScenario large30k -DemoAnalysisLatencyMs 15` (debug build, on disk store)

The Mac target was built for this (spec 005 S2, minimum); see "Mac" below. Window present and on screen
(`CGWindowList`); no screenshot could be taken (screen recording is not granted to the tools in this
session), so the rendered Home was not seen.

| Run | Observed |
|-----|----------|
| Before the fixes (first run) | 30,000 photos checked in 3 min 26 s. Screenshots 1,386 and 50 videos listed at 0 of 30,000 checked. Footprint grew 228 MB to 500 MB during the scan and **653 MB** during the last results build, which was still running at 100% CPU 30 s after the scan ended when the app was stopped (the same build took 281 s offline); 364 MB at rest |
| After the fixes | Scan 7:12:07 to 7:15:50 (3 min 43 s). Results shown at 0, 512, 1,536, 4,064, 6,624, 14,272, 16,800, 19,392, 21,952, 24,576, 27,200, 29,824 and 30,000 checked. Peak footprint **378 MB** (about 140 MB of it the window's graphics), **88 MB and 0% CPU** 20 s after the scan ended. Final results: duplicates 2,213, similar 12,012, blurry 1,232, screenshots 1,386, videos 50, the same as the offline build of the first run's store |
| Killed with SIGKILL at about 6,900 of 30,000 and started again on the same store | The window showed the saved results (duplicates 418, similar 2,835, blurry 288, screenshots 1,386) 1 s after launch; the scan resumed from 6,912 two seconds after launch and went on at the same speed; peak 273 MB |

In the first run the results shown mid-scan lagged by the length of the build (the line prints the count
when the build ends); the second run's builds were short enough to follow the scan.

## Package and app builds

| Check | Result |
|-------|--------|
| `swift test --package-path Packages/CleanupKit` | 187 of 187 (includes the accuracy suites and the baseline library on the Mac) |
| `scripts/check-no-network.sh` | clean (also checks the Mac entitlements file) |
| iOS Simulator, iOS device (unsigned), macOS debug and macOS release builds | all succeed |
| Simulator UI suite (iPhone 17 Pro, iOS 26) | 29 of 29, with the 2 new `StagedResultsTests` (quick wins before any photo is checked; removing screenshots while the scan goes on) |
| Mac, final build, `large3k` | window on screen (504 by 703); results at 0, 512 and 1,504 checked |

## Mac (spec 005 S2, minimum)

Built by a side agent in its own worktree and merged here: package platforms `[.iOS(.v18), .macOS(.v15),
.visionOS(.v2)]` (the visionOS package build was also checked), `PhotoKitLibrary` and `LongExposure`
behind `canImport(Photos)`, a multi-platform `project.yml`, a sandbox plus Photos-library entitlements
file with no network key (the check script fails if one is added), `ScanKeepAlive` with the existing
`ScanContinuation` on iOS and `MacScanKeepAlive` on the Mac (process activity while scanning; pause at
sleep, resume at wake; Dock percentage), and `NSTreatUnknownArgumentsAsOpen=NO` so launch arguments such
as `-DemoScenario standard` are not taken for files to open (without it the window never appears).
An ad-hoc signed sandboxed build ran the demo scan the same way.

Not done on the Mac: Settings scene, commands, app delegate, icon, the access screen's explanation for
no library, sleep/wake auto-pause (untested), PhotoKit on a real Mac library (never run: the access
screen and the delete confirmation are unverified), the Mac UI-test plan.

## Open

- A 30,000-photo scan on a phone in the background. The author's phone was not connected. What the
  system does to the app in the background was not observed, only what the app does to deserve it:
  measured memory and CPU. If a phone scan still ends, the run's `Console` log for the app and the
  `.ips` reports under Xcode's Devices window are the next evidence.
- 100,000 items (`ScaleBench --count 100000`; the candidate pair streaming and the 4,000-photo profile
  cache are bounded, the pair count is not).
- Defer feature print and face quality (Decision 2), and measure how much of a phone's per-photo time is
  preview fetch and decode, which decides whether it is worth it.
