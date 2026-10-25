# Research: Phased Cleaning for Large Libraries

Six independent research agents examined the current code, the SDK headers, and two proposals
for phased cleaning, and measured the scale hazards on a Mac. This file keeps the evidence
and the decisions. **Measured** means a number produced by the benchmark in
`research-prototypes/bench30k` on one Apple M4 Max (14 cores, 36 GB), Release build,
synthetic data. **Estimate** means scaled or reasoned, and no phone was measured.

## R1. Two proposals, one plan

| | A. Value first (steps) | B. Time windows (clean as you go) |
|---|---|---|
| Idea | Order the work by value for cost. Metadata first, one cheap pixel pass, costly Vision work only for candidates. | Split the library into date windows of about 2,000 photos and fully analyze one at a time, newest first. |
| First result | Seconds for screenshots and videos, about 30 s for the first photo results with a small first block | About 30 s for the first window of about 500 photos |
| Memory and launch | Needs persisted groups and edges to stop rebuilding at launch | Bounded by window size by construction |
| Hardest part | An incremental results engine with a stability contract | Groups that span windows: who owns them, how older windows' counts shrink, how selections merge |
| Changes the UI | Adds a plan list above the categories | Replaces the category list with a timeline of windows |
| Fit with 003 | Chunks gain a phase | One session per window |

**Decision**: take the step order and metadata gates from A, and the newest-first blocks, the
small first block, and the governor policy from B. Publish snapshots at block boundaries from
the existing builder instead of building either proposal's hardest part. Reasons:

- A snapshot from the same builder equals a one-shot scan by construction (FR-014), which is
  the strongest correctness test available.
- Ownership across windows (B) and an incremental engine (A) are both new correctness
  problems. The measured numbers do not yet show that either is needed: the Release results
  build takes 0.67 s at 30,000 items. The cost is memory and the debug build (R5).
- Duplicates do not depend on time, so a library-wide step with newest-first blocks finds
  them in one place; windows would need a separate cross-window pass anyway.

An incremental engine stays available as stage S5 if measurements after S3 and S4 require it.

## R2. What phasing saves, honestly

Measured on the M4 with synthetic 512×384 images: the analyzer takes 14 ms per item
sequentially, 193 items per second at 4 lanes. The Vision feature print is about 3 ms of the
14 (about 21%), the thumbprint 0.7 ms. The split of the other 10 ms (aesthetics, face quality,
sharpness, hash) was not measured, because synthetic noise images make the Vision timings
meaningless. The 20 items per second of 001 means about 200 ms per item per lane, roughly 14
times the Mac's compute, so on a phone preview fetch, decode, the Neural Engine, and heat very
likely dominate. That is an inference.

Model library of 30,000 assets (assumed, not measured): 25,500 stills, 2,700 screenshots,
1,800 videos; 35% of non-screenshot stills have a neighbour within 60 s; 10% of stills are
below the sharpness margin. In the free app videos are not analyzed (spec FR-004a), so the
1,800 videos cost nothing in the phased column; the proposals' video-copy step is Pro only.

| | Today | Phased (this plan) |
|---|---|---|
| Vision requests | about 81,000 | about 11,650 (about 86% fewer; feature prints about two thirds fewer) |
| Preview fetches | 30,000 at 512 px (videos included) | about 24,700 photos at 512 px; no video frames in the free app; no second fetch when fused |
| Time to first result | whole scan, then a results build | seconds for step 1; about 30 s for the first block |
| Total on the model phone (estimate) | about 10 min wall | about 5 min wall |
| At the 20 items per second floor (estimate) | about 25 min | about 12 min |
| Stored per item | about 5.4 KB | the same until S4 changes where blobs live |

These are estimates from the proposals' figures, recomputed for a 512 px first pass (the
proposals assumed 256 px, which this plan does not adopt, R7). They support the direction
and not any number promised to users. Spike S2 replaces them with phone measurements.

## R3. Device capability

Signals that exist on the target platforms (header-verified by the research):

| Signal | API | Use |
|---|---|---|
| Memory | `ProcessInfo.physicalMemory` | seed ceiling: under 4 GB compact, under 8 GB standard |
| Cores | `ProcessInfo.activeProcessorCount` (read per chunk; can drop under thermal throttling) | at most cores minus 1 items in flight |
| Thermal | `ProcessInfo.thermalState` and its notification (read once before registering) | main dynamic input |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` and its notification | cap width, hold optional steps |
| Charging, battery (iOS family) | `UIDevice` battery monitoring | gate optional steps; treat unknown as unplugged |
| Memory headroom (iOS) | `os_proc_available_memory()` (iOS 13, unavailable on macOS) | pause under the floor |
| Neural Engine | `VNRequest.supportedComputeStageDevices` for the feature print request | guard only: no Neural Engine means the compact seed |
| Form factor | platform checks, `UIDevice.userInterfaceIdiom` | battery-powered or not, head-worn or not |

Measured on the M4: the feature print saturates at 2 lanes (332 items per second at 1,
433 at 2, 4, and 8), and forcing CPU only was about 8 times slower (33 to 35 items per
second). The Swift-struct form of the compute-device property is in the 27.1 interface but
aborted at load on the macOS 26 runtime; use the `VNRequest` form and verify it on the
deployment OS. The API cannot say which device Vision will use, so only timing proves it.

**Decisions**: seed the profile from memory, cores, Neural Engine presence, and form factor,
never from a model list and never from the network. Treat the seed as a ceiling. Record the
measured items per second of the first 200 real items (kept, not throwaway) for the time
estimate and for Settings. Do not move above the seed automatically until real devices have
fitted the thresholds; the cut points the research suggested (12, 30, and 90 items per second)
are provisional. Never let conditions or tier change the preview size or the analysis recipe
(R7). Do not name a tier to the user.

## R4. How results are built and loaded

Measured: `store.items()` on a fresh 30,000-item store took 1.25 s and grew resident memory
from 15 to 569 MB, about 19 KB per item against about 5.4 KB stored. A second call overlapped
with the first reached 762 MB. The launch pipeline (load, then build) peaked at 853 MB. The
Release build takes 0.67 s and adds about 55 MB. In a Debug build the same build takes 95 s at
30,000 items on the Mac, which is why the author's phone hit the 10 second launch watchdog.

So the problem at launch is memory in Release and time only in Debug. Three ways to cut it,
to be chosen by spike S1 with a measurement of resident memory at 30,000 items:

| Option | Idea | Risk |
|---|---|---|
| a. Partial fetch | `FetchDescriptor.propertiesToFetch` excluding the two blob columns | Whether blob attributes fault lazily and stay out of memory is not verified |
| b. External storage | mark blob columns as externally stored | Changes the on-disk layout of existing rows; migration unproven |
| c. Split entity | blobs in a separate record keyed by asset id, read by id for candidate pairs | Most predictable; needs lazy migration of old rows (read the new record, else the old columns) |

The detectors need little of each item: duplicates need the hash and, for a candidate pair,
both thumbprints (1.5 k to 77 k pairs measured); similar shots need the feature print only for
time neighbours, in a sliding window; the other four need metadata and scalars.

A saved snapshot removes the launch build entirely when nothing changed. A store revision
counter, bumped by any item write or removal, tells whether the snapshot is stale.

## R5. Measured scale (M4 Max, Release unless noted)

| Case | Time | Peak memory | Note |
|---|---|---|---|
| Results build, 5,000 / 10,000 / 20,000 / 30,000 | 0.08 / 0.16 / 0.40 / 0.67 s | 28 / 57 / 84 / 120 MB | exponent 1.28 from 10 k to 30 k; quadratic part overtakes at about 46 k |
| Duplicate detector alone, 30,000 | 0.27 s | +5 MB | hash index 0.19 s, exactly 0.085 × photos² inner visits |
| Similar shots alone, 30,000 | 0.33 s | +2 MB | 1.6 window pairs per photo; with real feature prints 0.56 s and +50 MB decoded |
| Four other detectors | about 1 ms each | | linear |
| Planner, 30,000 vs 30,000 | 0.02 s | | negligible |
| Clustered hashes, 5% / 15% of photos | 0.39 / 1.36 s | | 9.7 k / 77 k candidate pairs; cost grows with the square of the clustered count |
| Similar shots, 3,000 photos in one minute | 42.8 s | 87 MB | 4.7 M pairs at 9.1 µs; the 60 s window has no cap |
| Store write, 30,000 in chunks of 32 | 6.5 s | 128 MB | 6.8 ms per checkpoint, flat from first to last chunk |
| `items()` on 30,000 | 1.25 s | 569 MB (762 MB overlapped) | about 19 KB resident per item |
| Launch: load, then build | 2.15 s | 853 MB | |
| Debug build, 30,000 | 94.8 s | 108 MB | 142 times Release; 17.7 s at 10,000 |
| Thumbprint pair, Release / Debug | 30 µs / 12 ms | | about 400 times slower in Debug |

Caveats: one Mac, synthetic data (uniform random hashes, white-noise thumbprints), most cases
run once, warm page cache. Real libraries have more hash collisions and more same-minute
clusters than the baseline, so the stress cases are the better guide to the worst case. Phone
figures elsewhere in this plan are the research's own 2 to 4 times scaling.

Also found, not benchmarked: `CleanupResults.category(of:)` and `group(containing:)` are
O(n) per call, so any screen that calls them per row is quadratic at 30,000 (task T052).

## R6. Thermal behaviour

Today: pause at serious or critical, resume when cool (002). The research proposed a ladder:
fair halves width, serious runs one-wide for up to 120 s, then pauses. **Decision**: adopt
only the fair step. The one-wide serious rule has no evidence and could hold a phone at
serious longer than pausing would. A step up needs 60 s at the better level, and the existing
30 s after fair stays for resuming from a pause.

## R7. Preview size stays at 512 px

Proposal A fetched 256 px for the hash pass. The hashes were calibrated on 512 px previews:
the 10-bit dHash distance, the 0.85 detail correlation and the 98% recall target. A 256 px
request may also be served from a larger cached derivative. **Decision**: keep one preview
size for every device and condition. Stored fingerprints then stay comparable, and the
recipe version stamp only changes on purpose. A cheaper first pass is a later optimization
that needs both accuracy suites at both sizes first.

## R8. Testing without the hardware

- `RunProfileTests`: table-driven over thermal × Low Power × power × memory × profile, plus
  the monotonicity property (a worse condition never raises width or enables a step).
- `GovernorTests`: hysteresis and the thermal ramp under a manual clock, so 30 minutes run
  in milliseconds. The clock conforms to the standard `Clock` protocol.
- `CapabilityProbe` and `ConditionsProvider` protocols with fakes named by class (3 GB phone,
  16 GB desktop on mains, laptop on battery), as the research listed.
- `FakePhotoLibrary` gains per-item latency so slow, medium, and fast libraries exercise the
  measured-speed path.
- A 30,000-item fake-library scenario with a scripted thermal and charging timeline.
- UI tests with launch arguments, in the pattern of the demo scenarios.
- On a real phone and on the Mac, a local report of items per second and the thermal timeline
  through the baseline library harness (`docs/BASELINE_LIBRARY.md`), which already records
  device facts and scan speed.

## R9. Considered and not adopted

- **Per-date windows with ownership** (R1): complexity without a measured need.
- **A hash-only sweep of every photo first** to find library-wide duplicates earlier: fetches
  each preview twice.
- **Unattended analysis while charging** (a processing task): touches 001 FR-005a. Left as a
  decision for later (spec Decisions 4).
- **A visible "likely copies" category** from equal timestamps and sizes: could be retracted by
  pixels, and views must not retract.
- **Camera-picked burst keepers** (amends 001 FR-008): useful and cheap, separate decision.
- **Showing a tier name or a depth picker**: the plan statement and "Stop after this step"
  give the same control without a vocabulary the user has to learn.
- **A video-copies step** (poster-frame hash for videos with a duration twin, in proposal A):
  Pro only since 2026-10-18: the free app does not analyze videos; video analysis is a
  one-time $2 Pro feature, not built yet (see specs/004-phased-cleaning/spec.md FR-004a). Not
  built since 2026-10-24: there is no Pro version (specs/016-free-photos-only/spec.md). Large Videos stays
  because it reads file sizes, not pixels.
- **tvOS and watchOS**: see spec 005.
