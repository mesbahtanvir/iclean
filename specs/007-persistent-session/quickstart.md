# Quickstart: Validate Persistent Review Session

Nothing here is run yet. Commands marked "(flags set by T0xx)" name something a task creates.
Phone figures are targets until the on-device scenarios below have been run and recorded in
`validation-log.md`. Use `<UDID>` for the phone, as in 003.

## Unit guarantees

```bash
swift test --package-path Packages/CleanupKit --filter "ResultsRevisionTests|StateRecordTests|StoreCommitTests|ReviewIntentTests|ReviewSessionTests|ReviewStateWriterTests|RemovalGateTests|ResultsSnapshotTests|LaunchPlannerTests|ReconcileTests|DeferredStoreTests|RouteValidatorTests|FaultInjectionTests|ScanWriteFailureTests|StoreMigrationTests"
```

Expected: all pass. The macOS package build skips iOS-only files, so follow it with an `xcodebuild` for
the simulator and for the iPhone (run `xcodegen generate` after adding files).

## Scenario 1: kill -9 loop during checkpoint and decision writes (SC-001)

The dev-only `CrashHarness` target loops store writes (scan checkpoints, decision saves, snapshot
saves). The test starts it, waits for a readiness line, SIGKILLs it at a seeded random offset (20 to 350
ms, including during open), copies the store files **together** (`.store`, `-wal`, `-shm`) and checks the
copy.

```bash
swift test --package-path Packages/CleanupKit --filter CrashLoopTests
```

Or by hand (flags set by T010):

```bash
swift build --package-path Packages/CleanupKit --product CrashHarness
for i in $(seq 1 100); do
  work=$(mktemp -d)
  Packages/CleanupKit/.build/debug/CrashHarness --store "$work/iclean.store" --mode mixed --seed "$i" &
  pid=$!
  sleep "0.$((RANDOM % 8 + 1))"
  kill -9 "$pid"; wait "$pid" 2>/dev/null
  mkdir "$work/copy" && cp "$work"/iclean.store* "$work/copy"/
  sqlite3 "$work/copy/iclean.store" 'PRAGMA integrity_check;'
done
```

Expected in all 100 runs: `ok` from the integrity check; the decisions row equals the last or the next
committed generation (never a mix); the `results` row is absent or passes the gate; no scan chunk is `done`
without its results and no results exist without their chunk recorded (003 SC-004). A copy that
leaves out the `-wal` is not a valid test of durability (it loses commits without an error).

## Scenario 2: fault injection on a copy of the store (SC-009)

Each case damages a copy of the store trio, opens it through `DeferredStore`, and checks the state shown.

| Damage | Expected |
|---|---|
| zero the header | open fails (`NSCocoaError` 259 or `NSSQLiteErrorDomain` 26); volatile notice "Progress won't be saved this time"; files untouched; no "Your library looks clean"; no crash |
| truncate the file | open fails (`NSSQLiteErrorDomain` 11); same as above |
| flip a byte in an interior data page | open and count succeed; the first full read throws 11; load-failure state, not "clean"; nothing deleted; "Delete saved data" offered |
| delete the `-wal` | opens normally in an earlier consistent state (the recent commits are gone, no error is thrown); the revision and the snapshot roll back together; a scan resumes from its last surviving checkpoint |
| open a store written by a newer format (meta `formatVersion` and state `version` above ours) | opens; unknown state rows ignored; results rebuilt; choices start from the suggestions; items intact |
| flip one byte inside a `results` or `decisions` payload (page valid) | checksum fails; row deleted silently; snapshot gives a rebuild, decisions give the suggestions |
| truncate a payload, or give it an unknown `version` | same as the line above |
| wrong `builderKey` | snapshot not shown and rebuilt; decisions kept |
| open throws the data-not-yet-available error (4618) once, then works | waited out and retried; no damage notice |

## Scenario 3: kill and relaunch on the simulator

Run through `xcodebuild` from a terminal, not from Xcode with a debugger attached, so
`XCUIApplication.terminate()` is a real SIGKILL.

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:icleanUITests/PersistenceTests
```

(`PersistenceTests` is created by T022, T026, T032 and T041; the tests use `-PersistStore` and no
`-ResetStore` on the second launch.)

| Test | What it does | Expected |
|---|---|---|
| `testSelectionSurvivesKill` | untick and tick photos, wait 3 s, terminate, relaunch | same ticked photos and the same "Remove N" count |
| `testKeeperChoiceSurvivesKill` | Keep This One on a copy, wait, terminate, relaunch | same keeper, same removable copy |
| `testSelectionSurvivesForegroundReload` | untick, send to background and back (a rebuild runs) | ticks unchanged (today they reset) |
| `testRelaunchShowsResultsWithoutRescan` | finish a scan, terminate, relaunch | category rows within 3 s, no scan row, no "Updating results" |
| `testRestoresCategoryAfterKill` | open a group, wait, terminate (foreground) and again after backgrounding | lands on the group, no Home flash, scrolled to the last photo |
| `testGroupDissolvedFallsBackToCategory` | `deleteDuringReview` demo removes a member while the app is dead | opens the category (or the group if it still exists) |
| `testCrashDuringRestoreFallsBackToHome` | DEBUG `-CrashOnRestore` (added by T039), launch twice | third launch shows Home with the Continue reviewing row |
| `testKilledInsideConfirmSheetRelaunchesWithoutSheet` | open the confirm sheet, terminate, relaunch (before saved places exist) | Home or the last screen, no sheet |
| `testRelaunchLandsOnNonModalScreenAfterKillInConfirmSheet` | open the confirm sheet from a group, terminate, relaunch | category or group screen, never the sheet |
| `testKillDuringRemovalReconciles` | DEBUG argument keeps the demo library's deletions across launches (added by T026) | absent photos are gone from the lists; present photos still ticked; no automatic removal |
| `testDeleteAllData` (extended) | tick, Delete All Data, background, relaunch | no choices, no saved screen, no saved results |
| cold-start tests | sample the accessibility tree during the first 2 s | no "Scan Library" and no "Your library looks clean" before the state is known |

## Scenario 4: the removal check

With the demo library: select photos, then (in the same test or with the demo library's deletion hooks)
delete one, edit one, make one a favorite, and delete the kept copy of one group; open the confirm sheet.
Expected: "Checking selection" with Remove off, then the totals without the four photos and the whole
group, a count of what was left out, and Remove removes exactly what the sheet shows (SC-007). Change
results behind the open sheet: nothing on the sheet moves.

## Scenario 5: kill and restore on the iPhone, from a Mac

First run (builds the demo library and a finished scan, keeps the store):

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -PersistStore -ResetStore -DemoScenario dates -AutoScan -TraceScan
```

On the phone: untick a few photos, Keep This One on a copy, open a group, wait 3 seconds. End the app
without a clean exit (swipe it away from the app switcher, or relaunch with `--terminate-existing`). Second
run (note: no `-ResetStore`, no `-AutoScan`):

```bash
xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.mesbahtanvir.iclean -- -UITesting -PersistStore -DemoScenario dates -TraceScan
```

Expected (FR-001, FR-006, FR-007): the group screen is the first content, with the same ticks and the same
keeper, and no scan starts. After a swipe-away the first launch within 24 hours still returns to the
screen. Change the phone's clock forward more than 24 hours: Home shows the Continue reviewing row and the
ticks are still restored. Record the time to first content frame in a Release build (SC-004).

## Scenario 6: nothing new leaves the device (Constitution V)

```bash
scripts/check-no-network.sh
```

Expected: "no networking APIs found". Also confirm no photo identifier appears in a log line from the new
code (review item), and that `PrivacyInfo.xcprivacy` needs no new required-reason entry (the Saved screen
reads sizes and times from the saved rows, not from file attributes).

## Scenario 7: Release benchmark (SC-004, SC-013)

Promote `research-prototypes/bench30k` to a maintained Release target (T003). At 30,000 and 100,000 items
record: snapshot bytes, decode time, resident MB after restore versus after a rebuild, time from process
start to first content frame. Debug builds are about 142 times slower and mean nothing here.

## Scenario 8: on-device soak (manual, record in validation-log.md)

On the owner's iPhone with the real library, after a Release install over the existing store (copy
`.store`, `-wal` and `-shm` together before the first launch):

1. First launch over the real store: "Preparing your library" shows only if the open takes over 400 ms;
   record the open time with and without the migration.
2. Force-quit mid-scan, relaunch: scan resumes, review state intact.
3. Tick and untick, force-quit within 3 s of the last tap: nothing older than 2 s is lost.
4. Open the photo viewer, kill the app: relaunch lands on the group, not the viewer.
5. Kill during the system delete dialog: relaunch drops the photos that were deleted, keeps the others
   ticked, removes nothing by itself.
6. Restart the phone, open the app after the first unlock: results appear without a rescan.
7. Kill the app while it is in the background under memory pressure (open several heavy apps).
8. Run once with the battery low and power it off (a power loss can lose the last seconds of choices; the
   store must come back consistent).
9. Switch to Limited access while the app is closed: the saved copy is not shown and the Limited
   selection is respected.
10. Check `FileAttributeKey.protectionKey` of the store, `-wal` and `-shm` after the first unlock.
11. Photos with bursts and Live Photos: confirm the gate and the visible-set check keep burst frames
    (the check that gates S4 and S6).
12. Delete a photo in Photos while iclean is dead: it is gone from the lists at launch and from the sheet.

Expected: no crash, no "Your library looks clean" before the state is known, and every result recorded.
