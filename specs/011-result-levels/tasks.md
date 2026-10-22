# Tasks: Levels for Similar Shots, and Unimportant Photos

## Package

- [X] T001 `ResultLevel`, `LevelSummary`, `ResultLevels`, `CleanupCategory.hasLevels/defaultLevel/preselects(at:)`; `CategoryResult.level/levels`; `CategoryDetector.detectLevelled(items:all:)` with a default
- [X] T002 `SimilarShotsDetector`: pair strength (`pairLevel`), edges once, one union-find per level, the same in parallel; `SimilarThresholds` for the tight and wide rules
- [X] T003 `UnimportantDetector`, `UnimportantThresholds`; `CleanupCategory.unimportant` after `.blurry`
- [X] T004 `DefaultResultsBuilder`: levelled detections, keeps an empty levelled category at a non-default level, preselects by level
- [X] T005 `BuilderKey` carries the thresholds and the chosen levels; `ResultsSnapshot.Category` carries `level` and `levels` (optional)
- [X] T006 `StandardPipeline.detectors(... levels:)`

## App (small, to merge with the calm-design work)

- [X] T010 `AppEnvironment.levels`, `LevelPreferences` (kept across launches), `AppModel.setLevel` (rebuilds at once)
- [X] T011 `Formatting.swift`: title, icon and explanation of Unimportant, the words for each level
- [X] T012 `CategoryView`: segmented level control with counts, "Nothing at this level."

## Test and measure

- [X] T020 `ResultLevelTests` (pair strengths on a grid, the medium level equals the old rule on 4,000 random pairs, nesting, summaries, parallel = serial per level, preselection, an empty level stays, Unimportant score/vetoes/ordering/neighbours/no-Vision, builder precedence, snapshot, builder key)
- [X] T021 `LevelsFlowTests` (UI): the control, "Same scene" selects nothing, "Same shot" restores the suggestion
- [X] T022 `ScaleBench --levels-profile <store>`: level counts and the spread of pair distances

## Later

- [ ] T030 Calibrate the tight and wide Similar rules and every Unimportant weight on real libraries (the explorer) and a labelling pass
- [ ] T031 Reasons on each Unimportant photo ("shaky · alone · no location") in the list
- [ ] T032 Classification and saliency (pets, landscapes, documents, "random object") as a later Vision pass, after the first results (reconcile with spec 010: a bitmask of passes done)
- [ ] T033 Stricter linkage at "Same scene" so long sequences of slightly different frames do not chain into one group
- [ ] T034 Reach "Same scene" when the default level lists nothing (today the category is absent then)
