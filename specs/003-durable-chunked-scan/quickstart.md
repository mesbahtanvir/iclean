# Quickstart: Validate Durable Chunked Scan

## Unit guarantees

```bash
swift test --package-path Packages/CleanupKit --filter "DurableScanTests|ScanPipelineTests|StoreTests"
```

Expected: all pass (guarantees G1–G10 in [contracts/services.md](contracts/services.md)).

## Scenario 1 — Kill and resume on the simulator

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:icleanUITests/EdgeCaseTests/testInterruptedScanResumesAfterRelaunch
```

Expected: the app is terminated mid-scan, relaunched, Home offers Resume, and results
appear.

## Scenario 2 — Kill and resume on the iPhone, from a Mac

Start a persisted demo scan (6 s per item), kill it after about 25 s, relaunch with the
same store, and watch the trace:

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -PersistStore -ResetStore -DemoScenario verySlow -AutoScan -TraceScan
```

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -PersistStore -DemoScenario verySlow -AutoScan -TraceScan
```

Expected (FR-003, FR-009): the second run's first `progress N/23` line shows N equal to
the last saved count of the first run (at most one chunk behind what was shown), the
count never decreases, and the scan completes. Settings → Recent scans shows one scan
with "interrupted and resumed".

## Scenario 3 — A photo that hangs

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -DemoScenario poison -AutoScan -TraceScan
```

Expected (FR-006, FR-007): the scan completes about 20 s × 3 attempts later than usual,
the Scanning screen shows "1 couldn't be checked", and results are otherwise identical.

## Scenario 4 — Nothing new leaves the device

```bash
scripts/check-no-network.sh
```

Expected: "no networking APIs found".
