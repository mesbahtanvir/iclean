# Validation log: levels for Similar Shots, and Unimportant photos

Run on 2026-10-21 on the author's Mac (M4 Max, release benchmark builds). The libraries are synthetic (the app's own
`large30k` demo library and the bench's 512 px library), so the counts below show that the machinery works and how the
levels behave on photos with known structure; they say nothing about how well the thresholds suit real photos (spec T030).

## What stayed the same

| Check | Result |
|-------|--------|
| Results digests on the kept 30,000-item stores, built with the new code and the new category | `fa169c4d97929604` (demo) and `30b0ab850af1d956` (bench): the same as before, to the digit |
| The medium level against the rule that existed before (`isSameMoment`) | equal on 4,000 random pairs (400 pairs × 10 feature-print distances, with and without a burst id) |
| The default level's groups against the old loop's connected sets | equal (`theDefaultLevelGivesTheGroupsTheDetectorAlwaysGave`) |
| Serial and parallel at every level | equal groups and summaries (`everyLevelFindsTheSameWithManyThreads`) |
| Cost of Similar Shots with the levels | serial 0.50–0.56 s on the demo store and 0.50 s on the bench store (0.59–0.60 s before); parallel 0.18–0.21 s (0.18 s before). The miniature correlation is worked out only when a rule asks for it |

## `ScaleBench --levels-profile` on the kept 30,000-item stores

Similar Shots among every analyzed photo; Unimportant before Blurry and Similar take their share, so those counts
include the photos Blurry would list (1,232), and in the real build they come out as nothing.

| | Demo library | Bench library |
|---|---|---|
| Almost identical | 0 groups | 670 groups, 1,406 photos |
| Same shot (today's rule) | 4,485 groups, 12,458 photos | 4,620 groups, 18,153 photos |
| Same scene | 4,619 groups, 14,662 photos | 4,620 groups, 18,311 photos |
| Pairs within 60 s | 27,725 | 27,722 |
| Feature-print distance < 0.04 / 0.04–0.10 / 0.10–0.22 / ≥ 0.22 | 0 / 3,200 / 14,417 / 10,108 | 1,290 / 17,006 / 9,296 / 130 |
| Miniature correlation ≥ 0.7 | 1,019 | 6,581 |

The demo library's burst frames are shifted copies, so none is "almost identical"; the bench library's variants
differ less. Real photos will spread differently: this is what the explorer is for.

## Tests and builds

| Check | Result |
|-------|--------|
| `swift test --package-path Packages/CleanupKit` | 308 of 308 (292 before, plus 16: `ResultLevelTests`) |
| Simulator UI suite (iPhone 17) | 35 of 35 pass, including the new `LevelsFlowTests` |
| iOS simulator and macOS app builds | pass |

**A bug the UI test found:** `ReviewIntent.defaults` recomputed the default selection from the category alone, so at
"Same scene" the app still selected the photos the builder had left unselected. Fixed to use `preselects(at:)`; covered
by `theSelectionAfterReplayingDecisionsFollowsTheLevelToo` and `LevelsFlowTests`.

## Not done, not observed

- Real libraries: no threshold has been checked against photos a person labelled. Unimportant lists nothing preselected for
  that reason. The simulator has no Vision, so Unimportant (which needs it to trust "no face") lists nothing there.
- The screen was not looked at in a window (the Mac screen was not available): the control was exercised by the UI test only.
- The interplay with spec 010 (deferred Vision work) is a message to that session and the "Interplay" section of the spec,
  not code; the two must be reconciled before both ship.
