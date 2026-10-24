# Tasks: 016 Free and photos-only

**Input**: [spec.md](spec.md). No plan document: the entry removes code and amends text, and
designs nothing new.

- [X] T001 Delete `Packages/CleanupKit/Sources/CleanupKit/Models/ProFeatures.swift`,
  `Packages/CleanupKit/Sources/CleanupKit/Grouping/DuplicateVideoDetector.swift`,
  `Packages/CleanupKit/Tests/CleanupKitTests/Unit/DuplicateVideoDetectorTests.swift` and
  `icleanUITests/DuplicateVideosFlowTests.swift` (FR-003).
- [X] T002 Drop the `features:` parameter and every use of it: `ScanPipeline` (both initializers,
  `plan`, `quickCheck`, both `analyze` call sites and `analyze` itself), `ScanPlanner.plan` and
  `needsNoAnalysis` (with the "analyze stored videos once Pro is on" rule),
  `StandardPipeline.detectors`, `Detectors.all`, `AppEnvironment.make` and `LaunchArguments.features`
  with `-ProVideoAnalysis`, `AppModel.builderKey`, `BaselineRunner`, ScaleBench (FR-002, FR-003).
- [X] T003 Remove `CleanupCategory.duplicateVideos` and `GroupType.duplicateVideos`, and their
  branches in `ResultsBuilder`, `GroupDetailView`, `Formatting`, `CategoryStyle` and
  `Components.ItemNoun` (FR-003).
- [X] T004 `BuilderKey`: drop `videoAnalysis`; drop the Duplicate Videos threshold from
  `thresholds` (FR-004).
- [X] T005 Tests follow: `VideosAreNotAnalyzedTests` without its Pro half (one new check that
  Large Videos is the only video detector and reads no analysis), `StagedCleanupTests`,
  `ResultsSnapshotTests`, `ResultLevelTests`, `DateAwareKeeperTests`, `BaselineHostTests` (FR-003).
- [X] T006 Documents: README; docs/DESIGN.md, docs/SCAN_PIPELINE.md, docs/APP_PLATFORM.md,
  docs/BASELINE_LIBRARY.md; dated notes in specs 001 (spec, plan, quickstart, research,
  data-model, contracts/services, tasks), 003, 004 (spec, plan, research, tasks), 005, 007
  (data-model), 008, 010, 012 (FR-005).
- [X] T007 Verify: CleanupKit `swift test`, the simulator build of the app, lint of the touched
  files, the leftover search (Success criteria). Results in the log below.
- [ ] T008 When 015 lands: add the 2026-10-24 note to its "nothing in this entry is Pro" sentence
  (FR-005).

## Verification log

2026-10-24, on this branch at its first commit, Mac (Apple silicon), Xcode 27:

- Leftover search of `Packages`, `iclean`, `icleanTests`, `icleanUITests`, `scripts`, `project.yml`
  and `.github` for `ProFeatures`, `ProVideoAnalysis`, `videoAnalysis`, `analyzeVideos`,
  `duplicateVideos`, `DuplicateVideo`: nothing.
- `swift format lint` on every touched Swift file: clean.
- `swift build --build-tests` of CleanupKit: built. `swift test`: 347 tests in 39 suites passed
  (the CoreData "file is not a database" lines in its output come from the store-fault tests, as
  always).
- `xcodebuild build-for-testing`, scheme `iclean`, iPhone 17 Pro simulator: TEST BUILD SUCCEEDED
  (the app, `icleanTests` and `icleanUITests` compile without the switch).
- `xcodebuild test-without-building` on the same simulator, `icleanTests` and
  `icleanUITests/LargeVideosFlowTests`: TEST EXECUTE SUCCEEDED; the Large Videos flow passed
  (nothing preselected, only the chosen video removed).
- Not run here: the rest of the UI suite and the baseline library check on a device; neither
  touches a path this entry changed beyond what the tests above cover.
