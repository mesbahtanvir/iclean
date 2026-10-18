# Quickstart: Validate iclean on Every Platform

## Build matrix (SC-009)

```bash
xcodegen generate
xcodebuild build -project iclean.xcodeproj -scheme iclean -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO
xcodebuild build -project iclean.xcodeproj -scheme iclean -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO
xcodebuild build -scheme CleanupKit -destination "generic/platform=visionOS Simulator"
swift test --package-path Packages/CleanupKit
```

## Scenario 1: iPad (SC-001, SC-008)

```bash
xcodebuild test -project iclean.xcodeproj -scheme iclean -destination "platform=iOS Simulator,name=iPad Pro 11-inch (M5)"
```

Rotate to landscape, open Duplicates, and confirm the category list stays and the group opens
beside it. Narrow the window to a third (Split View): Scan and a category row stay reachable.
Confirm no string says "iPhone" and none mentions the Dynamic Island.

## Scenario 2: Mac (SC-003 to SC-006)

Use a separate macOS user or a virtual machine with a test Photos library, never a personal one.

1. Build and run the Mac target. Start a scan, hide the window: the Dock icon shows progress and
   the scan speed does not drop.
2. Sleep and wake the Mac during the scan: it pauses at the sleep and resumes at the wake.
3. Quit with Command-Q during the scan, relaunch, tap Resume: it continues, repeating at most
   one piece.
4. In a group, press Space, arrows, Return, and Delete. Delete only opens the sheet.
5. Command-A and a Shift-click range: no keeper is marked.
6. Check the entitlements:

   ```bash
   codesign -d --entitlements - build/DerivedData/Build/Products/Debug/iclean.app | grep -c network
   ```

   Expect 0.

## Scenario 3: Vision Pro in compatibility mode

Run the iPad build on a visionOS simulator, then on a headset when available. Start a scan, close
the window: the scan pauses; reopen: it resumes. There is no error about a continued task.

## Scenario 4: the baseline everywhere (SC-002)

```bash
scripts/run-baseline.sh sim "iPad Pro 11-inch (M5)"
scripts/run-baseline.sh device <iPhone UDID>
scripts/run-baseline.sh mac --allow-real-library       # test user or VM only
scripts/compare-baseline-reports.py Fixtures/baseline-reports/*.json
```

A check that differs between columns is marked. Read the capabilities row first.

## Scenario 5: nothing leaves the device

```bash
scripts/check-no-network.sh
```

The script also fails if the Mac entitlements file names a network key.
