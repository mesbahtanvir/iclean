# Feature Specification: Levels for Similar Shots, and Unimportant Photos

**Feature Branch**: `011-result-levels`

**Created**: 2026-10-21

**Status**: Implemented (levels, the Unimportant detector, a segmented control on the category screen, tests, a
threshold explorer); thresholds are starting values to be calibrated on real libraries

**Input**: "For similar shots, a distinction between very similar and slightly similar, with a threshold the person
can pick. A new cleanup, unimportant pictures: a little shaky, not about a person, some random object; with levels
(most likely, probably, maybe) so the person chooses how far to look."

**Builds on**: [008-staged-cleanup-at-scale](../008-staged-cleanup-at-scale/spec.md) (results, staged builds),
[007-persistent-session](../007-persistent-session/spec.md) (decisions are per photo),
[009-parallel-scan](../009-parallel-scan/spec.md) (the Neural Engine is the scan's ceiling, so a new Vision pass costs
scan time). Reconciled with spec 010 (deferred Vision work): see Interplay.

## Defaults chosen (the brainstorm's recommendations)

1. **One Similar category with a level control**, not three categories. Levels are cumulative: choosing "Same scene"
   shows everything "Almost identical" and "Same shot" show, and more.
2. **Duplicates are unchanged.** What counts as a duplicate does not change; burst frames where nothing moved that pass
   the duplicate rule stay in Duplicates (first matching category wins, as before). The default Similar level, "Same
   shot", is today's rule exactly, so a person who never touches the control sees today's results.
3. **Three fixed stops**, no slider. Underneath, a pair has a continuous strength, so the stops can be retuned.
4. **Decisions are per photo** (007), so choosing another level does not lose ticks or kept copies; only the group a
   photo is shown in changes.
5. **Unimportant v0 uses signals already stored** (sharpness, face quality, time neighbours, album, edits, location,
   aesthetics where it exists). No new Vision pass, so the scan costs nothing more. Nothing in it is preselected.
6. **The level the person picks is a build input**, kept in `ResultLevels`; changing it rebuilds results (1 to 2 s on 30,000
   items on the Mac, spec 009) and the saved snapshot is keyed by it.

## Requirements

- **FR-001**: `ResultLevel` has three ordered values, `tight < medium < wide`. A category with levels
  (`CleanupCategory.hasLevels`: `.similar`, `.unimportant`) has a default level (`.medium` for Similar, `.tight` for
  Unimportant) and builds only the chosen one into `CategoryResult.groups`, plus `CategoryResult.level` and
  `CategoryResult.levels`, a summary (groups, photos, removable) of every level among the candidates the detector saw.
  Both default to `medium`: for Unimportant "Probably", because "Most likely" is expected to be rare and a default that
  lists nothing would hide the category. A category with levels whose chosen level lists nothing is kept (empty) when
  the level is not the default and another level lists something, so the person can step back; at the default level it
  is absent, as before.
- **FR-002**: A pair of photos within 60 s has a **strength**: the tightest level it qualifies for.
  - `tight` (Almost identical): feature-print distance < 0.04 and thumbprint correlation ≥ 0.7; without a feature
    print: correlation ≥ 0.85. Burst membership alone does not make a pair tight.
  - `medium` (Same shot): exactly today's rule (burst id, or distance < 0.1, or correlation ≥ 0.5 and distance < 0.15;
    without a feature print: correlation ≥ 0.5).
  - `wide` (Same scene): `medium`, or distance < 0.22 and correlation ≥ 0.3; without a feature print: correlation ≥ 0.35.
  The groups at a level are the connected sets of the pairs at that level or tighter, plus burst members at `medium`
  and `wide`. Levels nest: every group at one level lies inside one group at the next.
- **FR-003**: At the default level the results MUST equal those of the code before this spec (same groups, keepers,
  selection). Parallel and serial comparison MUST agree at every level (009 FR-006).
- **FR-004**: Similar at `wide` preselects nothing; at the other levels it preselects as before. Unimportant never
  preselects. (`CleanupCategory.preselects(at:)`.)
- **FR-005**: `UnimportantDetector` lists a still photo only if **all** of these hold, whatever its score: no face was
  found (`faceQuality == nil`) and Vision ran; not portrait mode; not long exposure; not a favourite; in no album; not
  edited; and it is soft (sharpness < 0.70). "Vision ran" matters because without Vision "no face" means nothing. The
  results loader reads feature prints only for photos with a neighbour, so a lonely photo's own print is always empty
  there; Vision is taken to have worked when any photo in the library has a print, until spec 010 gives each photo its
  own flag. The score then adds: sharpness < 0.55 → 3, < 0.62 → 2, otherwise 1; no other photo within 60 s (among
  everything examined, not only what earlier categories left) → 2; no location → 1; a known aesthetics score below 0 → 2.
  Levels by score: `tight` ≥ 7, `medium` ≥ 5, `wide` ≥ 3. Photos are listed most likely first. It runs after Blurry in
  the category order, so a photo Blurry takes is not listed twice.
- **FR-006**: `BuilderKey` includes every new threshold and the chosen levels; the snapshot stores each category's level
  and level summaries (optional fields, so older snapshots still open, and are rebuilt because the key differs).
- **FR-007**: The Similar and Unimportant screens show the three levels with their counts in a segmented control and
  let the person pick one (`AppModel.setLevel`, which saves the choice and rebuilds at once even with a list open);
  Home lists Unimportant when it is not empty. The choice is kept across launches.

## Interplay with spec 010 (deferred Vision work), reconciled

Spec 010 (merged first) skips the feature print and face quality for photos that no detector can use them for, and
records what it skipped per photo (`Analysis.skippedVision`, a bitmask). Unimportant's candidates are exactly the lonely
photos that rule skips, and its "no person" veto needs the face pass to have run. What 011 does about it:

- **The face pass is decided inside `DefaultAnalyzer`, once sharpness is known** (010 Decision 8 left the choice to 011):
  a still that is soft (sharpness < 0.70) and that nothing protects (no album, no edit, not a favourite, not portrait mode
  or a long exposure: `UnimportantDetector.isCandidate`) gets the face pass even where the neighbour rule skipped it. The
  flag records the outcome. Sharp lonely photos, most of them, still skip both requests.
- **`UnimportantDetector` reads the per-photo flag**: a photo whose `skippedVision` contains `.faceQuality` is never listed.
  The library-wide check that Vision works at all (any print or face quality anywhere) remains, because a face pass that ran
  and failed leaves no mark.
- The repair rule needs nothing new: a lonely soft photo stores `skippedVision == .featurePrint`, which is disjoint from what
  a library without neighbours demands, and when a neighbour arrives the demand is `.all` and the photo is analyzed again.
- Known limit: the decision uses the metadata at scan time. A photo that was in an album when scanned (face pass skipped) and
  is later removed from it is not listed until it is analyzed again.
- `wide` keeps the 60 s window on purpose, so Same scene adds no demand to the neighbour rule.
- `SimilarShotsDetector.pairLevel` keeps 010's rule that a pair with a skipped print waits for the repair, except frames of
  one burst, which group without a print.

## Not done / decisions left for real data

- Thresholds above are first guesses except the Same shot rule (008's). `ScaleBench --levels-profile` prints the level counts
  and the distribution of pair distances on a kept store so they can be set on a real library, and a labelling pass is needed
  for Unimportant before anything is preselected.
- v0 cannot tell a pet, a landscape or a whiteboard from a random object. Classification and saliency are a later Vision pass
  (cost: spec 009), best run as a second phase after the first results are shown.
- Reasons ("shaky · alone · no location") for each listed photo; the data exists, the screen does not show it yet.
- Chaining at `wide`: connected sets can join long sequences of slightly different frames; a stricter linkage is a later option.
