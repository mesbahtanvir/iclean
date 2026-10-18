# Validation log: scan progress outside the app and durable chunked scan

What has been run, when, and what is still open. Times are the author's local time.

## Automated

| Check | Result |
|-------|--------|
| CleanupKit unit tests (`swift test --skip AccuracyTests`) | 105 of 105, 12 runs in a row without a crash |
| CleanupKit accuracy tests (duplicates, blur, mixed library) | 7 of 7 |
| `scripts/check-no-network.sh` | clean |
| Simulator UI tests (23) | 23 of 23; the NoNetwork plan passes |
| `StoreMigrationTests` against `Fixtures/previous-store` | 2 of 2; fails with a required column and no default |

Flaky tests fixed on the way (both also failed on the commit before this work):
`testChangingTheKeeper` (review list order depended on store order) and
`AccessibilityTests.testMainScreens` (the changing "Last scan N seconds ago" text).

## Simulator, with a trace (2026-10-18, iPhone 17 Pro simulator)

The simulator has no background task scheduler, so these exercise the fallback path
(grace period, automatic resume). Vision is also unavailable there; the app tolerates it.

| Scenario | Observed |
|----------|----------|
| Leave the app 4 s into a 36 s scan, return 52 s later | Grace period started at +1 s, "Background time ran out; pausing" at +27 s with **16 of 23 saved** (whole chunks of 4); on return "Resuming after background time ran out" and the scan finished 23 of 23 without a tap |
| Leave the app near the end of the scan | Paused at 23 of 23, resumed on return, completed |
| Kill the app at 8 of 23 (`simctl terminate`), relaunch on the same store | First event after relaunch **8 of 23** (not 0); the interrupted chunk reran one item at a time (26 s for 4 items); finished 23 of 23 |
| One photo that never returns a preview | Three timeouts at 20 s with backoff; scan finished in 73 s with `failed=1`, never stalled |

## iPhone 17 Pro, iOS 26.6.2 (2026-10-18)

Run against the demo library with a temporary store, so the real library was not touched.

| Scenario | Observed |
|----------|----------|
| Start a scan | The system granted the continued processing task at once ("Continued processing task submitted", then "started") |
| Leave the app 15 s into a 36 s scan (Settings in front for 45 s) | The scan kept running in the background and **finished at 23 of 23 while another app was in front** |
| Kill the app at 8 of 23, relaunch on the same store | First event after relaunch **8 of 23**; the interrupted chunk reran one item at a time (26 s for 4 items); finished 23 of 23 |
| One photo that never returns a preview | Three timeouts at 20 s with backoff; finished in 72 s with `failed=1` and `notScanned=2` (one is the iCloud-only demo photo) |

### Found on the phone, not by any test: launch killed by the watchdog

The app could not start on the phone with its real library. Four crash reports between 10:36
and 12:25 show the same cause: `AppModel.onLaunch` built results (duplicate grouping) on the
main thread, more than 10 seconds, and iOS ended the app (`scene-update watchdog`,
`0x8BADF00D`). The demo library is too small to show it, and the same code ran at launch
before this work. Fixed by building results on a background task, discarding a build made
stale by a newer one or by a change to the results, and showing "Updating results…" instead
of "Your library looks clean" while it runs. After the fix the app stayed up for more than a
minute on the real library, including its first launch over the existing store (the
migration).

## Still open

- Stop in the system progress display (Dynamic Island or Lock Screen), then Resume in the
  app: needs a person to tap it. The trace shows the task is granted and progress is fed to
  it; the Stop path itself (expiration, then a lossless pause) is covered by the unit tests
  and by the same pause path exercised by the grace-period run on the simulator.
- A heat pause on a real phone.
- How long the first results build takes on the real library (it now runs off the main
  thread, so it no longer matters for launch, but it is still CPU work at every launch; see
  the matching roadmap, P10 and P12).
