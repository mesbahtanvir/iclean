# Feature Specification: Blurry & Duplicate Photo Cleanup

**Feature Branch**: `001-photo-cleanup`

**Created**: 2026-10-11

**Status**: Draft

**Input**: User description: "Clean up blurry and duplicate pictures in your phone's photo library, to free up cloud storage space and declutter the Photos app."

**Scope note**: Clarification expanded v1 to also cover screenshots, duplicate videos,
and large videos (Stories 4–6).

## Clarifications

### Session 2026-10-11

- Q: What should count as a "duplicate" photo? → A: The same image at any size, quality, or format; edited versions (crops, filters) are not duplicates.
- Q: How strict should blur detection be by default? → A: Only obviously blurry photos are flagged.
- Q: Should flagged photos start out selected for removal? → A: Yes, everything flagged starts selected; the user unselects what to keep.
- Q: Should "similar shots" be in the first version? → A: Yes, similar shots ship in v1.
- Q: How should favorited photos be treated? → A: Never flagged for removal.
- Q: How should photos in the user's albums be treated? → A: Flagged, with a badge naming their albums.
- Q: When should scans run? → A: Full scan when the user taps Scan; quick check for new photos on app open; nothing in the background.
- Q: How should removal be confirmed? → A: One summary sheet, broken down by category, confirmed with one tap.
- Q: Which duplicate copy should be suggested as the keeper? → A: Best quality first; if tied, the oldest.
- Q: Should photos that are blurry on purpose be left out of blur detection? → A: Skip portrait-mode and long-exposure photos; still check night and motion shots.
- Q: Which extra kinds of clutter should v1 handle? → A: Screenshots, duplicate videos, and large videos.
- Q: Which devices should v1 support? → A: iPhone only.
- Q: Which screenshots should be shown, and should they start selected? → A: All screenshots, pre-selected.
- Q: Which videos should Large Videos show, and should they start selected? → A: The 50 largest videos, none pre-selected.
- Q: How will iclean make money? → A: v1 is fully free; pricing is decided later.
- Q: Which languages and accessibility support should v1 have? → A: English only, with full accessibility support.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Remove duplicate photos (Priority: P1)

A user's photo library has built up copies of the same picture: images saved twice from
messaging apps, re-imported files, and edited copies kept next to the original. The user
opens iclean, which scans the library on the phone and shows groups of duplicates. In each
group, one photo is suggested as the one to keep. The user reviews the groups, changes the
keeper if they want, and removes the rest in one confirmed action. They see how much space
they got back.

**Why this priority**: Exact and near-exact duplicates are pure waste. Removing them is
low-risk because a copy always stays, so it is the safest and clearest first win.

**Independent Test**: Load a test library with known duplicate groups, run a scan, confirm
every group is found with a sensible keeper suggested, delete the extras, and confirm only
the kept photo remains and the reported space saved matches the removed files.

**Acceptance Scenarios**:

1. **Given** a library with 3 identical copies of one photo, **When** the user runs a scan,
   **Then** the copies appear as one group of 3 with exactly one marked "keep".
2. **Given** a duplicate group, **When** the user picks a different photo as the keeper,
   **Then** the previous keeper is marked for removal and the new one is kept.
3. **Given** the user has selected duplicates to remove, **When** they confirm,
   **Then** the selected photos are moved to the Photos app's recoverable "Recently Deleted"
   area and the app shows the number of photos and the storage freed.
4. **Given** the user has selected duplicates, **When** they cancel the confirmation,
   **Then** nothing is deleted.

---

### User Story 2 - Remove blurry photos (Priority: P2)

The user wants to clear out photos that are out of focus, shaken, or otherwise unusable.
iclean finds photos that are likely blurry and shows them in a reviewable list, blurriest
first. The user taps through, unselects any they want to keep, and removes the rest in one
confirmed action.

**Why this priority**: Blurry photos are common clutter, but deciding "blurry" is a
judgment call and a removed blurry photo may be the only copy, so it comes after
duplicates and always needs the user's review.

**Independent Test**: Load a test library with a known set of sharp and blurry photos, run
a scan, confirm the blurry ones are flagged and the sharp ones are not, then remove the
selected ones and confirm the result.

**Acceptance Scenarios**:

1. **Given** a library with sharp and clearly blurry photos, **When** the user runs a scan,
   **Then** the blurry photos are listed and sharp photos are not.
2. **Given** the blurry list, **When** the user opens a photo, **Then** they can view it full
   screen to judge it before deciding.
3. **Given** the user unselects some flagged photos, **When** they confirm removal,
   **Then** only the still-selected photos are removed.
4. **Given** a photo the user marked "keep" in a past review, **When** a later scan runs,
   **Then** that photo is not flagged again.

---

### User Story 3 - Thin out similar shots (Priority: P3)

The user often takes several shots of the same moment (bursts, multiple attempts at a group
photo). iclean groups these similar shots, suggests the best one (sharpest, eyes open,
best framed where detectable), and lets the user keep one or more and remove the rest.

**Why this priority**: Very useful for decluttering, but similar shots are not true
duplicates, so users need more control. It builds on the grouping and review from
Stories 1 and 2.

**Independent Test**: Load a test library with known sets of similar shots, run a scan,
confirm each set is grouped and a best shot is suggested, and confirm the user can keep
multiple shots from one group.

**Acceptance Scenarios**:

1. **Given** 8 burst shots of the same scene, **When** the user runs a scan, **Then** they
   appear as one similar-shots group with one suggested best shot.
2. **Given** a similar-shots group, **When** the user keeps 2 shots and confirms,
   **Then** only the other 6 are removed.

---

### User Story 4 - Clear out screenshots (Priority: P4)

Screenshots pile up and are rarely needed later. iclean lists the user's screenshots in
their own category so the user can review and remove them in bulk.

**Why this priority**: Easy, low-risk clutter to remove, but it takes less space than
duplicates or videos.

**Independent Test**: Load a test library with screenshots and regular photos, run a
scan, confirm only screenshots appear in the category, remove a selection, and confirm
the result.

**Acceptance Scenarios**:

1. **Given** a library with screenshots and camera photos, **When** the user runs a scan,
   **Then** only screenshots appear in the Screenshots category.
2. **Given** the Screenshots category, **When** the user confirms removal,
   **Then** only the selected screenshots are removed.

---

### User Story 5 - Remove duplicate videos (Priority: P5)

The user has the same video saved more than once. iclean groups duplicate videos like
duplicate photos, suggests a keeper, and removes the rest after confirmation.

**Why this priority**: Videos take far more space than photos, so each duplicate frees a
lot, but they are less common than duplicate photos.

**Independent Test**: Load a test library with known duplicate videos, run a scan,
confirm each group is found with one keeper, remove the extras, and confirm the space
reported.

**Acceptance Scenarios**:

1. **Given** 2 copies of the same video at different quality, **When** the user runs a
   scan, **Then** they appear as one group with the higher-quality copy as the keeper.
2. **Given** a duplicate-video group, **When** the user confirms, **Then** only the
   non-keeper copies are removed.

---

### User Story 6 - Review large videos (Priority: P6)

The user wants to know which videos use the most space. iclean lists videos from largest
to smallest with their size and length, so the user can decide what to remove.

**Why this priority**: Often the single biggest space win, but every decision is personal,
so iclean only informs and never judges.

**Independent Test**: Load a test library with videos of known sizes, open the category,
confirm they are ordered by size with correct sizes shown, and remove a chosen one.

**Acceptance Scenarios**:

1. **Given** videos of different sizes, **When** the user opens Large Videos,
   **Then** videos are listed largest first with size and length.
2. **Given** the Large Videos list, **When** the user selects one video and confirms,
   **Then** only that video is removed.

---

### Edge Cases

- **Huge libraries**: tens of thousands of photos. Scanning shows progress, keeps the
  phone usable, and can be paused, stopped, and resumed without starting over.
- **App closed mid-scan**: the next launch continues from where the scan stopped.
- **Photo access**: if the user grants access to only some photos, iclean scans only
  those and says so. If access is denied, iclean explains why it needs access and how to
  grant it, and scans nothing.
- **Photos stored only in the cloud**: only the preview on the phone is analyzed; nothing
  is downloaded (FR-014). If a photo has no usable preview, it is skipped and counted in
  a "not scanned" total shown to the user.
- **Favorites, albums, and edits**: favorited photos are never flagged for removal; a
  favorite in a group is always kept, and if several photos in a group are favorites,
  all of them are kept. A photo in a user-made album can be flagged and shows a badge
  naming its albums, since removing it also removes it from them. Edited versions are not treated as duplicates of their
  original (FR-002).
- **Item in several categories**: a photo can appear in only one category at a time, in
  this order: Duplicates, Similar, Blurry, Screenshots. It is listed where it first
  matches.
- **Videos stored only in the cloud**: as with photos, only what is already on the phone
  is analyzed (FR-014); nothing is downloaded.
- **Live Photos and photo bursts**: a Live Photo is treated as one photo. Burst photos are
  handled as similar shots (Story 3).
- **Library changes during review**: if a photo is deleted or changed elsewhere while the
  user is reviewing, it is dropped from the results and not acted on.
- **Intentional blur**: artistic shots (portrait-mode backgrounds, motion shots, night
  photos) may look blurry. Because every removal is reviewed, a wrong flag costs the user
  a tap, not a photo.
- **Removal fails**: if the phone refuses some or all removals, the user is told exactly
  which photos were not removed. Nothing is reported as freed that was not freed.
- **Nothing found**: the user sees a clear "your library looks clean" result.

## Requirements *(mandatory)*

### Functional Requirements

**Scanning**

- **FR-001**: System MUST scan the user's photo library entirely on the phone. No photo,
  preview, or derived data (such as fingerprints or blur scores) may leave the device
  (Constitution Principles I & II).
- **FR-002**: System MUST detect exact duplicates and near-exact duplicates (the same
  image at a different size, compression, or format). Edited versions (cropped,
  filtered, adjusted) are NOT duplicates and are never grouped with their original.
- **FR-003**: System MUST detect photos that are likely blurry or out of focus. The
  default sensitivity flags only obviously blurry, unusable photos, favoring fewer
  false flags over finding every soft photo.
- **FR-003a**: Portrait-mode photos and long-exposure Live Photos MUST NOT be flagged as
  blurry. Night and motion photos are still checked.
- **FR-004**: System MUST detect groups of similar shots of the same moment (Story 3).
- **FR-004a**: System MUST list all screenshots in a Screenshots category, newest first,
  all pre-selected (Story 4).
- **FR-004b**: System MUST detect duplicate videos (the same video at any size, quality,
  or format) and group them like duplicate photos (Story 5).
- **FR-004c**: System MUST list the 50 largest videos in a Large Videos category,
  largest first, with size and length. None start selected (Story 6).
- **FR-005**: System MUST show scan progress and allow the user to pause, stop, and
  resume a scan.
- **FR-005a**: A full scan runs only when the user starts it. Each time the app is
  opened, it quickly checks for photos added or changed since the last scan. No scanning
  happens while the app is in the background.
- **FR-006**: System MUST remember results between sessions so that unchanged photos are
  not rescanned, and later scans only process new or changed photos.

**Review**

- **FR-007**: System MUST show results in separate categories (Duplicates, Similar,
  Blurry, Screenshots, Duplicate Videos, Large Videos) with the number of photos and the estimated space each category would free.
- **FR-008**: For each duplicate group (photo or video), system MUST suggest a keeper:
  favorited first, then highest resolution and file quality; if still tied, the oldest.
  For similar-shots groups, the suggested best shot is the favorited one, else the
  sharpest.
- **FR-009**: Users MUST be able to view any flagged photo full screen and compare
  photos within a group side by side.
- **FR-010**: Users MUST be able to change selections: change the keeper, unselect
  individual photos, select or unselect a whole group or category.
- **FR-010a**: All flagged items in every category except Large Videos MUST start
  selected for removal (except each group's keeper and items protected by FR-011 or
  favorites). The user unselects what to keep. Large Videos start unselected.
- **FR-011**: Users MUST be able to mark a photo "keep" so it is never flagged again,
  and to clear these marks later.

**Removal**

- **FR-012**: System MUST NOT remove any photo without an explicit confirmation step: one
  summary sheet stating how many photos will be removed and how much space will be freed,
  broken down by category, confirmed with a single tap (Constitution Principle IV).
- **FR-013**: System MUST remove photos only by moving them to the Photos app's
  recoverable "Recently Deleted" area, never by permanent deletion, so the user can
  restore them for the period the Photos app allows.
- **FR-014**: For photos whose full-quality original is stored only in the cloud,
  system MUST analyze only the preview already stored on the phone and MUST NOT request
  or trigger a download of the original. Results based on a preview are marked as such
  in the review screens, and blur flags from previews are shown with lower confidence.
- **FR-015**: After removal, system MUST show the number of photos removed and the
  space freed, and remind the user that space is fully reclaimed once "Recently Deleted"
  is emptied.
- **FR-016**: System MUST keep at least one photo in every duplicate or similar group
  unless the user explicitly selects every photo in the group and confirms a separate
  warning.

**Privacy & data**

- **FR-017**: System MUST work with networking fully disabled and MUST make no network
  requests of its own (Constitution Principles II & V).
- **FR-017a**: All screens MUST support VoiceOver, Dynamic Type, and Reduce Motion.
  Every photo action available by gesture MUST also be available to VoiceOver users.
- **FR-018**: System MUST let the user delete all data iclean has stored (scan results,
  "keep" marks, settings) from within the app.

### Key Entities

- **Photo**: an item in the user's photo library (a photo, screenshot, or video). Key attributes: identifier in the
  library, capture date, size on storage, resolution, favorite status, edited status,
  album membership, whether the full original is on the phone.
- **Duplicate Group**: two or more photos showing the same image. Has one suggested
  keeper; the rest are candidates for removal.
- **Duplicate-Video Group**: two or more copies of the same video, with one keeper.
- **Similar-Shots Group**: two or more photos of the same moment that are not
  duplicates. Has one suggested best shot; the user may keep several.
- **Blur Result**: a photo's likelihood of being blurry, used to flag and order the
  blurry list.
- **Keep Mark**: a user's decision that a photo must never be flagged again.
- **Scan Session**: progress through the library, so a scan can resume and later scans
  only process new or changed photos.
- **Cleanup Summary**: the outcome of a removal: count, space freed, and any photos that
  could not be removed.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On a library of 10,000 photos, a first full scan finishes in under
  10 minutes on a phone from the last 4 years, and a repeat scan with no new photos
  finishes in under 30 seconds.
- **SC-002**: On a labeled test set, at least 98% of true duplicate groups are found, and
  fewer than 1% of suggested duplicates are not actually duplicates.
- **SC-003**: On a labeled test set, at least 85% of clearly blurry photos are flagged,
  and fewer than 10% of flagged photos are judged sharp by a human reviewer.
- **SC-004**: A user can go from opening the app to completing a duplicate cleanup in
  under 3 minutes for a library with 50 duplicate groups.
- **SC-005**: Zero photos are ever removed without a user confirmation, and 100% of
  removed photos can be restored from the Photos app's "Recently Deleted" area.
- **SC-006**: With networking blocked, every flow (scan, review, removal) completes
  successfully, and monitoring shows zero network requests made by the app.
- **SC-007**: 90% of test users report that the app's suggested keepers matched the
  photo they would have chosen.

## Assumptions

- v1 supports iPhone only; iPad and Mac are out of scope.
- The phone is an iPhone and the library is the built-in Photos app library, which may
  be synced with iCloud Photos. "Freeing cloud space" happens because Photos syncs the
  removal; iclean itself never talks to the cloud.
- v1 includes all six stories: duplicate photos, blurry photos, similar shots,
  screenshots, duplicate videos, and large videos. Documents and other file types are
  out of scope.
- Every removal is reviewed by the user; there is no automatic or scheduled deletion.
- The user can recover removed photos only through the Photos app's "Recently Deleted"
  area for as long as the Photos app keeps them there; iclean keeps no backups.
- Blur detection sensitivity uses a sensible default; an adjustable sensitivity setting
  may be added but is not required for v1.
- Shared albums and photos shared with the user by others are out of scope for removal.
- v1 is fully free with no paid features or limits. Pricing is decided later.
- Accounts and sign-in are out of scope; the app needs no account
  (Constitution Principle I).
- v1 is in English only; all text is ready for translation later.
