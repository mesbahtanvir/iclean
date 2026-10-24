# 016 Free and photos-only: there is no Pro version

**Feature Branch**: `016-free-photos-only`
**Created**: 2026-10-24
**Status**: Implemented on this branch
**Input**: "We will make this app totally free and github repo will be public for users to read."
Then: "Videos stay un-analyzed for everyone. Drop the Pro framing from code and docs, keep the app
photos-only, and write it up as a spec entry."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) (the pricing clarification,
Story 5), [004-phased-cleaning](../004-phased-cleaning/spec.md) (FR-004a, Decisions 6 and 7) and
[007-persistent-session](../007-persistent-session/spec.md) (the builder key). On 2026-10-18 the
owner put video analysis, and with it the Duplicate Videos category, behind a planned one-time $2
Pro purchase. The purchase was never built; the code carried a `ProFeatures` switch that was off in
every release build and on only under a debug launch argument. This entry closes that: iclean is
free, there is no paid version and none is planned, videos stay un-analyzed for everyone, and the
switch, the detector it guarded and every "Pro" sentence go. Where this entry and an earlier one
disagree, this one wins; everything it does not mention is unchanged.

## Clarifications

### Session 2026-10-24

- Q: "Totally free" could mean video analysis comes back for everyone, or that videos stay
  un-analyzed for good. Which? → A: Videos stay un-analyzed for everyone. The app is photos-only;
  Large Videos keeps ranking videos by file size, which needs no analysis.
- Q: The repository is public. Is a license part of this entry? → A: Not decided here. No LICENSE
  file is tracked, and "public for users to read" is met by visibility alone. Choosing a license is
  the owner's call and its own change.

## What changes

### FR-001 iclean is free
There is no paid tier, purchase, unlock, trial or limit, and none is planned; nothing in the app
or its documents offers one. The 2026-10-18 pricing decision (001 Clarifications, "How will iclean
make money"; 004 Decisions 6 and 7) is superseded. 004 Decision 7's constitution question is moot:
nothing needs a purchase check, so Principle II ("no license checks") is met as written, with no
amendment.

### FR-002 Videos are never analyzed, in any edition
004 FR-004a stands and loses its exception: no video frame is opened, hashed or compared, for
anyone. A video is stored with its metadata only (`AnalysisSource.metadataOnly`), is not counted as
"not scanned" and is never retried. Large Videos is the only category that lists videos, by file
size. (015 adds categories that read a video's metadata, such as screen recordings; those read no
frame either and are not affected.)

### FR-003 The Pro switch and the detector it guarded are gone
Removed: `ProFeatures`; the `features:` parameter of `ScanPipeline` (both initializers),
`ScanPlanner.plan` and `needsNoAnalysis`, `StandardPipeline.detectors`, `Detectors.all`,
`AppEnvironment.make` and `BuilderKey`; the planner's rule that re-analyzed stored videos once Pro
was on; the debug launch argument `-ProVideoAnalysis`; `DuplicateVideoDetector` and
`DuplicateVideoThresholds`; `CleanupCategory.duplicateVideos` and `GroupType.duplicateVideos`;
the tests `DuplicateVideoDetectorTests` and `DuplicateVideosFlowTests`, and the Pro half of
`VideosAreNotAnalyzedTests`. Code that told Duplicate Videos apart from the other categories (its
name, glyph, tint and explanation, the "videos" noun of the Remove bar, the Keep This Copy button
of a group) loses that branch. `KeeperRules.duplicateKeepers` stays: Duplicates uses it.

### FR-004 Saved results survive
`BuilderKey` loses its `videoAnalysis` field, and the Duplicate Videos threshold leaves its
`thresholds` string. A saved snapshot still carries the old field and decodes without it; the
changed `thresholds` string rejects it once, so the results are rebuilt from the store at the next
launch, as any threshold change does (007). A snapshot saved by a debug build with
`-ProVideoAnalysis` would hold a `duplicateVideos` group and not decode; it is rejected and rebuilt
the same way. Nothing in the store changes: `metadataOnly` videos stay as they are, and an old
store that still holds video analysis keeps it unused (004).

### FR-005 The documents say so
README states that iclean is free with no paid features, that it does not analyze videos, and that
the source is public so anyone can read what the app does with their photos. Every earlier spec and
reference document that states the 2026-10-18 decision carries a dated note pointing here (specs
001, 003, 004, 005, 007, 008, 010 and 012; docs/DESIGN.md, docs/SCAN_PIPELINE.md,
docs/APP_PLATFORM.md and docs/BASELINE_LIBRARY.md). The dated 2026-10-18 text stays as history and
is never deleted. Spec 015, on its own branch, says "nothing in this entry is Pro"; that sentence
gets its note when 015 lands.

## Success criteria

- A search of `Packages`, `iclean`, `icleanTests` and `icleanUITests` for `ProFeatures`,
  `ProVideoAnalysis`, `videoAnalysis`, `duplicateVideos` or `DuplicateVideo` finds nothing.
- `StandardPipeline.detectors()` lists Duplicates, Similar Shots, Blurry Photos, Unimportant,
  Screenshots and Large Videos, in that order, and `CleanupCategory` has those six cases.
- A full scan of a library with two copies of one clip requests no video preview, stores both
  videos as `metadataOnly`, lists both in Large Videos (larger first) and nowhere else, and
  reports zero not-scanned items (`VideosAreNotAnalyzedTests`).
- The baseline library check is unchanged: it never had a Pro run, and `videos.notAnalyzed`
  still holds.
- The package tests, the simulator build of the app and the lint of the touched files pass.
- No sentence in README, INSTALL or the app's strings mentions Pro, a purchase or a price.

## Out of scope

- A license for the public repository (Clarifications).
- Removing the 2026-10-18 history from the earlier specs; they are records.
- 015's categories for screen recordings and other clutter: metadata-only, untouched here.
