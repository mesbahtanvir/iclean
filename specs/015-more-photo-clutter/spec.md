# Feature Specification: More Photo Clutter

**Feature Branch**: `015-more-photo-clutter`

**Created**: 2026-10-24

**Status**: Draft

**Input**: User description: "More photo clutter: burst leftovers, Live Photo stills, screen recordings, and dark or pocket shots"

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) (categories, keepers, confirmation,
Recently Deleted), [004-phased-cleaning](../004-phased-cleaning/spec.md) (the free app does not
analyze videos, FR-004a), [006-date-aware-keepers](../006-date-aware-keepers/spec.md) (keeper rule
order), [007-persistent-session](../007-persistent-session/spec.md) (per-photo decisions, the
removal plan), [010-defer-vision-work](../010-defer-vision-work/spec.md) (which photos get Vision
passes) and [011-result-levels](../011-result-levels/spec.md) (burst frames inside Similar,
Unimportant). This entry adds four kinds of clutter the scan can find from what it already reads:
three new removal categories and one new action that is not a removal. Everything it does not
mention is unchanged. Where it disagrees with 011 about burst frames, this one wins.

## Clarifications

### Session 2026-10-24

- Q: Burst frames are grouped into Similar today (011 FR-002, at "Same shot" and wider). Where do
  they go now? → A: A new Bursts category, ahead of Similar in the category order, takes every
  burst with two or more frames in the library. Similar no longer unions burst members; a burst
  frame can still land in Similar on its own merits (a near-identical photo outside the burst),
  but then only the frame Bursts kept, since first matching category wins.
- Q: What does "Live Photo stills" remove? → A: The motion part only. The still stays, with the
  same date, location, favourite flag, caption and albums, and is no longer a Live Photo afterwards.
  This is a new action, "Keep Still Only", not a removal, and it is confirmed on the same summary
  sheet as removals, in its own section.
- Q: The platform cannot drop a Live Photo's motion part in place (the Photos app's "Live off" is an
  edit that keeps the movie on disk). How is the still kept? → A: iclean writes a new photo from
  the still, copies the capture date, location, caption and album memberships to it, and moves the
  original Live Photo to Recently Deleted, where it stays recoverable for at least 30 days like any
  removal. The still is a new photo in the library, so iclean treats the original as removed and
  the new photo as a photo it has already seen.
- Q: Do screen recordings count as "video analysis", which the free app does not do (004
  FR-004a)? → A: No. Listing screen recordings reads only what the library says about the file
  (its kind, length and size), exactly as Large Videos does. No frame is opened. Screen recordings
  are free.
- Q: Should Dark shots start selected? → A: Yes, like Blurry: these are photos with nothing in
  them. The same protections apply (favourites and edited photos never flagged, albums badged), and
  a photo in which a face was found is never flagged.
- Q: Should screen recordings start selected? → A: No. They are fewer, larger and more often kept
  on purpose than screenshots (a recorded bug, a how-to for a parent). All are listed, newest
  first, none selected, like Large Videos.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Keep one frame of each burst (Priority: P1)

A user holds the shutter and gets 12 frames of the same moment. The Photos app shows the burst as
one picture, so they never notice the other 11. iclean lists each burst as one group, with the
frame worth keeping suggested, and the user removes the rest in the usual confirmed action.

**Why this priority**: Bursts are the largest pure waste that today's scan leaves behind. A copy of
the moment always stays, so the risk is as low as with duplicates. The frames are known from the
library's own records, so the group costs almost nothing to build.

**Independent Test**: Load a library with three bursts of known sizes (12, 5 and 2 frames, one
burst with a frame the user picked in Photos, one with a favourited frame). Scan. Each burst is one
group in Bursts; the picked, favourited or sharpest frame is the keeper as the rule says; removing
the rest leaves exactly one frame of each burst; space saved matches the removed files.

**Acceptance Scenarios**:

1. **Given** a burst of 12 frames, **When** the user scans, **Then** Bursts shows one group of 12
   with exactly one frame marked "keep" and the other 11 selected.
2. **Given** a burst in which the user picked two frames in the Photos app, **When** the user
   scans, **Then** both picked frames are kept and the others are selected.
3. **Given** a burst with one favourited frame, **When** the user scans, **Then** the favourite is
   the keeper, whatever its sharpness.
4. **Given** a burst group, **When** the user marks another frame as the keeper, **Then** the
   previous keeper is selected for removal and the new one is kept, and the change survives
   closing the app (007).
5. **Given** a burst whose frames are all in the cloud with only small previews on the phone,
   **When** the user scans, **Then** the group is still listed (the frames are known without
   pixels) and the keeper falls back to the picked frame, else the first frame.

---

### User Story 2 - Keep only the still of Live Photos (Priority: P2)

Every Live Photo carries a short movie next to the picture, often larger than the picture itself.
Most of them are never played. iclean lists the Live Photos whose motion part is worth dropping,
shows how much space the motion parts take, and lets the user keep only the stills in one confirmed
action. The pictures stay exactly where they are.

**Why this priority**: On an iPhone library this is often more space than every other category
together, and nothing is lost that the user looks at. It is second because it is a new kind of
action and needs its own words on the confirmation sheet.

**Independent Test**: Load a library with 20 Live Photos of known still and motion sizes, one
favourited, one long-exposure, one edited in Photos. Scan. Live Photos lists the 17 that qualify
with the motion size each; after "Keep Still Only" on all of them, each is a plain photo with the
same date, location, albums and caption, the favourite and the long exposure are untouched, and the
space reported equals the motion parts dropped.

**Acceptance Scenarios**:

1. **Given** 20 Live Photos, **When** the user scans, **Then** Live Photos lists them largest
   motion part first, none selected, with the total motion size in the summary line.
2. **Given** a long-exposure Live Photo, **When** the user scans, **Then** it is not listed: its
   motion part is what makes it a long exposure (001 FR-003a).
3. **Given** a selected Live Photo, **When** the user confirms "Keep Still Only", **Then** a
   plain photo with the same picture, date, location, caption and album memberships is in the
   library, and the original Live Photo is in Recently Deleted.
4. **Given** the confirmation sheet with 3 duplicates to remove and 5 Live Photos to trim,
   **When** it opens, **Then** removals and "keep still only" are two separate sections, the
   button says both, and cancelling does neither.
5. **Given** a Live Photo trimmed in an earlier session, **When** the user scans again, **Then**
   the new still is not flagged as a duplicate of the original in Recently Deleted, and nothing
   about it is listed as new clutter unless it is.

---

### User Story 3 - Clear out screen recordings (Priority: P3)

Screen recordings pile up like screenshots and are rarely wanted for long. iclean lists them, newest
first, with length and size, and the user picks which to remove.

**Why this priority**: Simple and safe, and the library already says which videos are screen
recordings. It comes after the two bigger wins.

**Independent Test**: Load a library with 6 screen recordings and 10 other videos. Scan in the free
app. Screen Recordings lists exactly the 6, newest first, none selected, each with length and size;
no video frame is opened; removing two moves them to Recently Deleted.

**Acceptance Scenarios**:

1. **Given** a library with screen recordings, **When** the user scans, **Then** Screen Recordings
   lists all of them, newest first, none selected, with length and size.
2. **Given** the free app, **When** the user scans, **Then** screen recordings are listed without
   any video frame being opened (004 FR-004a holds).
3. **Given** a screen recording that is also one of the 50 largest videos, **When** the user
   scans, **Then** it is listed in Screen Recordings only (first matching category wins).

---

### User Story 4 - Remove dark and pocket shots (Priority: P4)

Photos taken by accident in a pocket or bag, against a lens cap, or into a black room: nearly
black, or nearly white, with nothing in them. iclean lists them darkest first, selected, and the
user unselects any they want to keep.

**Why this priority**: These are the photos most users delete by hand first, when they find them.
Last because a dark photo can be deliberate (a candle, a stage), so it needs the same review that
Blurry gets, plus the face check.

**Independent Test**: Load a library with 8 near-black pocket shots, 2 blown-out frames, a Night
mode photo of a street, a candle photo with a face, and 30 ordinary photos. Scan. Dark lists exactly
the 10 accidents, darkest first, selected; the Night mode photo, the candle photo and the ordinary
photos are not listed.

**Acceptance Scenarios**:

1. **Given** a near-black pocket shot, **When** the user scans, **Then** it is listed in Dark,
   selected.
2. **Given** a dark photo in which a face was found, **When** the user scans, **Then** it is not
   listed.
3. **Given** a favourited or edited dark photo, **When** the user scans, **Then** it is not listed;
   a dark photo in an album is listed with its album badge (001).
4. **Given** a photo that is both blurry and dark, **When** the user scans, **Then** it is listed
   in Blurry only (first matching category wins), and Dark comes before Unimportant so an accident
   is named as what it is.

---

### Edge Cases

- A burst with a single frame in the library (the user already deleted the rest) is not a burst
  group; nothing is listed.
- A burst whose frames are spread across the user's albums: the group is listed, badged with the
  albums, and album membership is a keeper tie-break (006) but does not protect frames from being
  selected.
- A burst frame marked "keep" (001 FR-011) is never selected; if every frame is kept, the group is
  not listed.
- A Live Photo whose full-quality still is not on the phone (cloud only): it is listed, since the
  sizes are known, but trimming needs the full still; if it cannot be read without a download at
  the time of trimming, the photo is reported as "could not change" and left as it is (001 FR-014:
  nothing is downloaded).
- A Live Photo trimmed while it is the keeper of a duplicate group: the new still becomes the
  group's keeper; the original goes to Recently Deleted with the rest.
- A Live Photo in a shared album or in the iCloud Shared Library is never listed in Live Photos:
  changing it would change it for others.
- A Live Photo that is also a duplicate: Duplicates comes first; if it is the keeper of its group,
  it is also listed in Live Photos (the only case where one asset is in two categories, because the
  second is not a removal).
- A screen recording longer than an hour, or larger than any other video: still listed in Screen
  Recordings, never in Large Videos.
- A photo whose preview is a cloud preview only (001 FR-014): Dark is judged on it with lower
  confidence, as Blurry is.
- A dark photo that is portrait mode or long exposure: not listed, as for Blurry (001 FR-003a).
- All four categories empty: nothing new is shown on Home.
- Scan in the Mac app: all four categories work the same; the Mac has no Live Photo capture but
  can hold synced ones.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The scan MUST list every burst that has two or more frames in the library as one
  group in a Bursts category. Bursts sits between Duplicates and Similar in the category order.
  Similar MUST no longer union frames by burst membership (011 FR-002 amended): burst membership
  neither makes a pair "Same shot" nor merges groups.
- **FR-002**: Each burst group MUST have at least one keeper, chosen in this order, first rule that
  decides wins: every frame the user picked in the Photos app (there may be several); else a
  favourited frame; else a kept frame (001 FR-011); else the sharpest frame that has the best
  face quality among frames with faces, if any frame has a face; else the sharpest frame; else, when
  no frame could be analyzed, the frame the library marks as the burst's representative; else the
  first by capture order. Every other frame starts selected, except kept frames.
- **FR-003**: The scan MUST list, in a Live Photos category, every Live Photo whose motion part
  can be dropped: not long exposure, not a favourite, not edited, not in a shared album or shared
  library, and not already trimmed. The list is largest motion part first, none selected, and each
  row shows the motion part's size. The category's summary line shows the total.
- **FR-004**: The action on Live Photos MUST be "Keep Still Only". iclean MUST write a new plain
  photo from the Live Photo's still, carrying its capture date, location, caption and album
  memberships, and only then move the original Live Photo to Recently Deleted (001 FR-013). If
  writing the still fails, the original MUST NOT be touched. Favourites are never listed (FR-003),
  so no favourite flag is copied. iclean MUST record the new photo as already seen so the next scan
  does not analyze it again as a stranger, and MUST treat the original as removed (007).
- **FR-004a**: The confirmation sheet MUST show removals and "keep still only" as two sections, with
  one button that names both ("Remove 12 and Trim 5"), and one cancel for both (001 FR-012).
  The iOS system confirmation covers both. After confirmation the result screen MUST report
  photos removed, photos trimmed and the space freed by each.
- **FR-004b**: Trimming MUST NOT download anything and MUST NOT open the motion part's frames; it
  works from the full-quality still the library holds on the device. A photo whose still is not on
  the device, or cannot be written, is reported as not changed and stays a Live Photo.
- **FR-005**: The scan MUST list all screen recordings in a Screen Recordings category, newest
  first, none selected, with length and size. This MUST be done from the library's description of
  the file alone, so it works in the free app (004 FR-004a). Screen Recordings sits between
  Screenshots and Duplicate Videos in the category order.
- **FR-006**: The scan MUST list, in a Dark category, still photos with nothing visible in them:
  nearly all black or nearly all white, judged on the same preview Blurry uses. A photo MUST NOT be
  listed if any of these hold: a face was found; portrait mode or long exposure; favourited; edited.
  The list is darkest first, all selected, album badges as in 001. Dark sits between Blurry and
  Unimportant in the category order.
- **FR-006a**: Dark MUST NOT list Night mode and other deliberately dark photos that still show
  something: the rule is on emptiness (how much of the picture is at the extremes with no
  structure), not on average brightness. On the baseline library (008) the rule MUST list no photo
  that a person would keep.
- **FR-007**: Category order after this entry: Duplicates, Bursts, Similar, Blurry, Dark,
  Unimportant, Screenshots, Screen Recordings, Duplicate Videos, Large Videos, and Live Photos as
  the one non-removal category, last. An item is in the first removal category that matches it
  (001 FR-007), and may additionally be in Live Photos.
- **FR-008**: Bursts, Screen Recordings and Live Photos MUST need no Vision work beyond what 010
  already gives burst frames (face quality), so a library of bursts and recordings scans as fast
  as its metadata reads. Dark MUST reuse the preview and the face result Blurry already has, adding
  no new preview decode.
- **FR-009**: Results at the default levels of Similar MUST equal today's results for every group
  that contains no burst frame (011 FR-003). Serial and parallel builds MUST agree (009 FR-006).
- **FR-010**: Home MUST show each new category only when it lists something, with a one-sentence
  caption each, as 014 FR-005 writes them: "Several frames of one moment. Keep the best, remove the
  rest.", "Live Photos whose motion you never play. Keep the still, drop the movie.", "Screen
  recordings, newest first.", "Photos with nothing in them: pocket shots and lens caps."
- **FR-011**: All of this MUST work with networking disabled and MUST make no network request
  (constitution II, 001 FR-017). VoiceOver, Dynamic Type and Reduce Motion apply to every new
  screen and row (001 FR-017a).

### Key Entities

- **Burst group**: the frames the library records under one burst identifier; its keepers and
  the user's decisions per frame (007).
- **Motion part**: the movie half of a Live Photo, with its size; dropping it is a trim, not a
  removal.
- **Trim record**: which Live Photos iclean has trimmed, kept with the session so they are not
  listed again.
- **Emptiness**: a per-photo measure of how much of the preview is at the dark or bright extreme
  with no structure; stored with the analysis like sharpness, so a rescan does not recompute it.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the baseline library (008), every burst with two or more frames appears as one
  group in Bursts, and no burst frame appears in Similar at the default level.
- **SC-002**: On a library of 500 Live Photos, "Keep Still Only" on all of them frees at least 40%
  of the space those photos took, and every photo keeps its date, location, albums and caption.
- **SC-003**: A scan of a 30,000-item library takes no longer than before this entry, within 5%,
  on the Mac ScaleBench run (009); the new categories add no preview decodes.
- **SC-004**: On the baseline library, Dark lists every seeded pocket shot and no photo a person
  would keep; Screen Recordings lists every seeded recording and no other video; no video frame is
  opened in the free app.
- **SC-005**: Removing and trimming from one confirmation sheet in one go moves the removed photos
  to Recently Deleted and leaves the trimmed stills in place, and the result screen reports both
  counts and both sizes.
- **SC-006**: The iOS simulator and the Mac build; existing UI tests pass with two assertions
  updated: the Similar test that expected a burst group, and the confirmation test that counts
  sections.

## Assumptions

- The platform cannot drop a Live Photo's motion part in place, so "Keep Still Only" is a write of
  a new still plus a removal of the original (Clarifications). The space it frees is the original's
  full size minus the new still's size, which is what the result screen reports.
- The frames the user picked in the Photos app and the frame the library marks as a burst's
  representative are readable with the burst identifier the scan already stores.
- "Screen recording" is a kind the library marks on the video, like "screenshot" on a photo; no
  guessing from dimensions or names.
- Emptiness is computed from the same preview as sharpness and stored with it; the thresholds are
  tuned on the baseline library and fixtures, with the Night mode and candle cases seeded.
- The Pro purchase (004) is unchanged: nothing in this entry is Pro.
- Data & Network: the scan reads burst identifiers, picked flags, Live Photo and screen-recording
  kinds and resource sizes from the library, and a per-photo emptiness score from the preview
  already decoded. All of it is stored in the local results store beside the existing analysis;
  the trim record lives in the session store (007). Nothing leaves the device; no network access.
