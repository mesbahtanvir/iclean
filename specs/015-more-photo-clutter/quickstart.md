# Quickstart: validating 015

Prerequisites: Xcode 26, the iPhone 17 simulator, a Mac. The baseline needs a simulator with the
Photos prompt answered once (see memory "iclean baseline library").

## 1. Package tests

```bash
swift test --package-path Packages/CleanupKit
```

Expect new suites to pass: `BurstDetectorTests`, `LivePhotosCategoryTests`,
`ScreenRecordingsCategoryTests`, `DarkDetectorTests`, `BurstKeeperTests`, `TrimRemoverTests`,
`ResultsBuilderTrimPassTests`, a snapshot round trip with the new fields, and the `BuilderKey`
string containing `burst` and `dark`. `ResultLevelTests` keeps passing with the burst union gone
(the test that unioned by burst id is rewritten to pair by prints).

## 2. Builds

```bash
xcodegen generate && xcodebuild -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17' build
```

```bash
xcodebuild -scheme iclean -destination 'platform=macOS' build
```

Both must build (the macOS package build alone skips iOS-only files).

## 3. UI flows (simulator, `-UITesting` demo library)

```bash
xcodebuild test -scheme iclean -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:icleanUITests/BurstsFlowTests -only-testing:icleanUITests/LivePhotosFlowTests -only-testing:icleanUITests/ScreenRecordingsFlowTests -only-testing:icleanUITests/DarkFlowTests -only-testing:icleanUITests/SimilarFlowTests -only-testing:icleanUITests/RemovalScreensTests
```

What to see:
- Home lists Bursts, Dark, Screen Recordings and Live Photos with their captions (spec FR-010).
- Bursts: two groups; the user-picked frame is the keeper; the others selected.
- Live Photos: four rows largest motion first, none selected; the favourite and the long exposure
  absent. Select two, Keep Still Only → the Confirm sheet shows a Trim section and the button
  "Remove 0 and Trim 2" (or just "Trim 2"); the receipt says 2 trimmed and the space.
- Screen Recordings: three rows, none selected, length and size on each.
- Dark: three rows selected, the Night-mode-like photo absent.
- Similar: the burst group that the old test expected is gone; the rest unchanged.

## 4. Baseline library (device or simulator)

```bash
scripts/run-baseline.sh
```

The V5 catalog expects: every seeded screen recording in Screen Recordings and no other video;
every seeded dark shot in Dark and none of the keepers; Live Photos listing the seeded pairs; no
video frame opened in the free run (the existing no-network and no-video assertions). Bursts are
checked on the host (`BaselineHostTests`), since PhotoKit cannot seed a shared burst identifier.

## 5. Scale (Mac)

```bash
swift run -c release --package-path Packages/CleanupKit ScaleBench --store <large30k store>
```

Build time within 5% of the number in `specs/011-result-levels/validation-log.md`; the run logs
no new preview decodes for Bursts, Screen Recordings or Live Photos (SC-003).

## 6. No network

```bash
scripts/check-no-network.sh
```

Must pass unchanged: the trim path uses resource reads with network off and writes locally.
