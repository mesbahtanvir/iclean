# Quickstart: Validate Scan Progress Outside the App

Builds on [001 quickstart.md](../001-photo-cleanup/quickstart.md). Screens and ids are in
[contracts/ui.md](contracts/ui.md); the API delta in [contracts/services.md](contracts/services.md).

## Setup

```bash
xcodegen generate
```

```bash
swift test --package-path Packages/CleanupKit --filter ScanPipelineTests
```

Expected: all pass, including the new guarantees G1–G4.

## Scenario 1 — Still no network (constitution Principle V)

```bash
scripts/check-no-network.sh
```

Expected: exits 0, "no networking APIs found". Then the NoNetwork UI test plan from 001
still passes:

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -testPlan NoNetwork
```

## Scenario 2 — Simulator: screen states and leave-and-return (fallback path)

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:icleanUITests/BackgroundScanTests
```

Expected: the Scanning screen shows `scan.whenYouLeave`; pressing Home mid-scan and
re-activating the app leaves the scan running (or auto-resumed) and results appear. The
simulator has no background task scheduler, so this proves the grace-period fallback.

## Scenario 3 — iPhone (iOS 26+): Dynamic Island, Stop, Resume

Install on a Dynamic Island iPhone (see [INSTALL.md](../../INSTALL.md)) with a library of
a few thousand photos, or seed the demo library.

1. Tap **Scan Library**. Expected: the Scanning screen's footnote says the scan keeps
   going while you use other apps.
2. Go to the Home Screen. Expected (FR-001, SC-001): within 5 s the Dynamic Island shows
   iclean with a progress indicator; long-press it to see "Scanning your library" and
   "N of M checked"; the count keeps rising. Lock the phone: the same appears on the
   Lock Screen.
3. Wait for it to finish. Expected (FR-004): the display disappears; opening iclean shows
   results without rescanning.
4. Start another scan (delete iclean data in Settings first to force a full scan), leave
   the app, then tap **Stop** in the expanded Dynamic Island. Expected (FR-006, FR-008):
   the display disappears; opening iclean shows "Stopped from outside iclean" with
   **Resume**; tapping Resume continues and the "N of M" count continues from where it
   stopped (SC-003).
5. Turn off **Settings → General → Background App Refresh** for iclean, start a scan, and
   leave the app. Expected (FR-010): the footnote said "Pauses when you leave iclean";
   about 30 s after leaving, the scan pauses; returning to iclean resumes it by itself.
6. Count the items in Photos before and after steps 1–5. Expected (FR-015, SC-005): the
   count is unchanged.

### Same check from a Mac, without touching the phone

The DEBUG build accepts launch arguments that start a scan of the demo library (6 s per
preview) and print a trace to the console:

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -DemoScenario verySlow -AutoScan -TraceScan
```

Then, from another terminal, put iclean in the background by opening Settings:

```bash
xcrun devicectl device process launch --device <UDID> com.apple.Preferences
```

Expected: "Continued processing task started", then `progress N/23 running` lines that
keep coming after Settings is in front, ending with `progress 23/23 completed`
(verified 2026-10-17 on an iPhone 17 Pro, iOS 26.6.2). Relaunch iclean normally
afterwards with `--terminate-existing` and no arguments.

## Scenario 4 — App closed from the app switcher during a background scan

Start a scan, leave the app, swipe iclean away in the app switcher, reopen it.
Expected (Story 3 scenario 4): Home offers **Resume Scan**; it continues from the last
saved point.
