# Quickstart: Validate Phased Cleaning

Run these after each stage in the plan. Numbers marked "reference" come from the baseline
library harness on a real device (`docs/BASELINE_LIBRARY.md`).

## Unit guarantees

```bash
swift test --package-path Packages/CleanupKit --filter "RunProfileTests|GovernorTests|PhasedScanTests|ReviewIntentTests|DurableScanTests"
swift test --package-path Packages/CleanupKit -c release --filter ScaleGuardTests
```

G1 to G10 in [contracts/services.md](contracts/services.md) each name their test. The scale
guards run in Release only; a Debug run is not meaningful (research R5).

## Scenario 1: quick wins before analysis (SC-001)

1. Seed a simulator with the large scenario and slow analysis:
   `-DemoScenario large30k -DemoAnalysisLatencyMs 200`.
2. Launch, grant access. Within 10 seconds Home lists Screenshots and Large Videos with counts
   while the plan row for Photos still says Waiting.
3. Remove one screenshot: the confirmation sheet appears first.

## Scenario 2: review while it runs (SC-002, SC-008)

1. Start a scan on the large scenario. After the first block, open Duplicates.
2. Toggle a selection and change a keeper. Wait for the next block.
3. The open list has not changed; a "N new" prompt shows. Tap it: new groups appear below.
4. Leave and reopen: the toggled selection and the keeper are as you left them.
5. Let the scan finish. The category counts equal a scan with `-OneShot`.

## Scenario 3: conditions (SC-007)

Launch with injected profiles and watch the plan statement and the log line
`[governor] width=… steps=… throttle=…`:

| Arguments | Expect |
|---|---|
| `-iclean-device compact` | Similar shots waits: "Waiting for your iPhone to be charging", Run now |
| `-iclean-device fast` | Photos fuse deep work; no Similar shots wait |
| `-iclean-conditions thermal=fair` | width halves; scan keeps going |
| `-iclean-conditions thermal=serious` | pauses; resumes after fair for 30 s |
| `-iclean-conditions lowpower=1` | only Quick wins and Photos run; later steps "Paused: Low Power Mode" |
| `-iclean-conditions battery=15,power=battery` | everything but Quick wins pauses |
| `-iclean-conditions memorywarning=1` | width halves for 60 s; scan is not ended |

## Scenario 4: kill in every step (SC-009)

Use `-DemoKillAfterChunks N` (from 003) with N spread across each step. Relaunch, Resume, and
confirm that each run completes, at most one piece repeats, and the final results equal
`-OneShot`.

## Scenario 5: the phone (reference)

```bash
scripts/run-baseline.sh device <UDID>        # records items per second and stage timings
```

Compare the report with the M4 figures in research R5. Then, on the same phone, install the
Release build with the 30,000-item scenario, kill it, and relaunch: Home is usable within
1 second and the last results within 2 seconds (SC-004). Record peak memory from Instruments
or the report's `memory` metric.

## Scenario 6: Mac scale (SC-005, SC-006)

```bash
specs/004-phased-cleaning/research-prototypes/bench30k/run_all.sh      # until T003 replaces it
```

Expect, in Release on the M4: results for 30,000 under 1 s and 200 MB; 3,000 same-minute
photos under 5 s; 15% clustered fingerprints under 3 times the ordinary time.

## Scenario 7: nothing new leaves the device

```bash
scripts/check-no-network.sh
```

Then run the no-network UI plan on the new flows. No network API is added by this feature.
