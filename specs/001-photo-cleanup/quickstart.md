# Quickstart: Validate Blurry & Duplicate Photo Cleanup

How to prove the feature works end to end. See [contracts/ui.md](contracts/ui.md) for
screens and [data-model.md](data-model.md) for rules.

## Prerequisites

- macOS with Xcode 27 and the iOS 26 or later simulator runtime
- XcodeGen (development-time only):

```bash
brew install xcodegen
```

## Setup

```bash
xcodegen generate
```

```bash
swift test --package-path Packages/CleanupKit
```

All unit tests pass, including the ResultsBuilder guarantees in
[contracts/services.md](contracts/services.md).

## Scenario 1 — No network, ever (SC-006, Principle V)

```bash
scripts/check-no-network.sh
```

Expected: exits 0 and prints "no networking APIs found".

Then run the UI tests with the simulator's networking disabled:

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -testPlan NoNetwork
```

Expected: scan, review and removal all succeed.

## Scenario 2 — Seed the test library

```bash
scripts/seed-simulator.sh "iPhone 17 Pro"
```

Imports `Fixtures/` (labeled duplicates, edits, bursts, sharp/blurry/portrait shots,
screenshots, duplicate videos) into the simulator's Photos library.

## Scenario 3 — Duplicates (Story 1)

1. Launch the app, allow access, tap **Scan**.
2. Open **Duplicates**.

Expected:
- Each labeled duplicate set appears as one group with one keeper (highest quality,
  then oldest); edited versions are not grouped with their originals.
- Non-keepers are pre-selected; the favorited fixture is never selected.
- Confirm → the summary sheet shows count and space → iOS asks → **Done** shows the
  same count; items are in the Photos app's Recently Deleted.

## Scenario 4 — Blurry, similar, screenshots, videos (Stories 2–6)

- **Blurry**: only the "obviously blurry" fixtures appear, pre-selected; portrait and
  long-exposure fixtures never appear.
- **Similar**: each burst fixture is one group with a suggested best shot; keeping 2 and
  confirming removes only the rest.
- **Screenshots**: all screenshots, newest first, all pre-selected.
- **Duplicate Videos**: the duplicate video pair is one group; higher quality is kept.
- **Large Videos**: up to 50 videos, largest first, none selected.
- An item never appears in two categories.

## Scenario 5 — Accuracy (SC-002, SC-003)

```bash
swift test --package-path Packages/CleanupKit --filter AccuracyTests
```

Expected report: duplicate recall ≥ 98% with < 1% false duplicates; blur recall ≥ 85%
with < 10% false flags.

## Scenario 6 — Performance (SC-001)

On a physical iPhone from the last 4 years with 10,000 photos: first full scan < 10 min;
second scan with no changes < 30 s. Record times in the PR.

## Scenario 7 — Resilience

- Kill the app mid-scan → relaunch → Home offers to resume; it continues from the saved
  point.
- Grant limited access → only shared photos are scanned and the app says so.
- Delete a photo in the Photos app while reviewing → it disappears from results.
- Cancel the iOS system prompt → nothing removed.
- Settings → **Delete all iclean data** → next launch starts fresh.
