# Feature Specification: Date-Aware Keepers

**Feature Branch**: `006-date-aware-keepers`

**Created**: 2026-10-18

**Status**: Implemented (rule, tests, explanation in the group screen, baseline checks)

**Input**: User description: "When you are suggesting what to keep and what to delete, you need to
consider the metadata attached to it. Some photos are exactly the same but the dates are different.
You need to figure out which date is most probably correct and keep that one."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) FR-008 (keeper suggestion) and
FR-016 (at least one photo of every group is kept). Before this feature the keeper of a duplicate
group was the favorite, else the highest resolution, else the largest file, else the oldest. Two exact
copies with different dates therefore ended on file size, which says nothing about which date is
right.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The copy with the most probable date is suggested (Priority: P1)

A person has the same photo twice. One copy was taken in June 2019. The other was saved from a
message in September 2023 and carries that date. The photos look identical. iclean suggests keeping
the June 2019 copy, so the photo stays in the right place in the timeline, and suggests removing the
other.

**Why this priority**: This is the request. Keeping the wrong copy leaves a photo under the wrong date
for good, and nobody can tell afterwards.

**Independent Test**: Build groups of exact copies that differ only in date, saved moment, location, or
a default date, and assert the suggested keeper for each, for every ordering of the copies.

**Acceptance Scenarios**:

1. **Given** two exact copies dated 1 Jun 2019 and 10 Sep 2023, **When** the keeper is chosen,
   **Then** the 2019 copy is the keeper, even if the 2023 copy has a larger file.
2. **Given** a copy dated the start of 1970 or 1904, exactly the start of 2001, with no date, or with a
   date in the future, and another copy with a possible date, **When** the keeper is chosen, **Then** the
   copy with the possible date is the keeper, even if it has a lower resolution.
3. **Given** one copy whose date is the moment it was added to the library and another copy that still
   carries an earlier capture date, **When** the keeper is chosen, **Then** the copy with the earlier
   capture date is the keeper.
4. **Given** a copy whose exact timestamp is shared by at least five different photos in the library (a
   bulk import stamped them alike; the copies of one photo and the frames of a burst count once or not
   at all), **When** it competes with a copy that has a unique date within a year, **Then** the unique
   date is preferred.
5. **Given** copies whose dates are within an hour of the earliest of them, **When** the keeper is
   chosen, **Then** the dates do not decide and file size does.
6. **Given** one copy has a location and another is known to have none, **When** the keeper is chosen,
   **Then** the copy with the location is preferred, unless a stronger rule applies. A copy whose
   location is not known yet is never counted as having none.
7. **Given** a favorite among the copies, **When** the keeper is chosen, **Then** every favorite is kept
   and no date rule applies (001 FR-008 unchanged).
8. **Given** copies whose dates are both believable and different, and different resolutions, **When** the
   keeper is chosen, **Then** the higher resolution is kept (see Decision 1).
9. **Given** copies of the same resolution whose dates are more than a year apart, **When** the keeper is
   chosen, **Then** the earlier date is kept even if it carries a small doubt (a scanned photo dated to the
   day, so to midnight, against a copy exported decades later).

---

### User Story 2 - The group says why (Priority: P2)

On the group screen, a copy whose date or details look less reliable than another copy's says so in one
short line ("Dated when it was saved, not when it was taken."). The suggested copy says its date shows no
sign of being wrong. The person can still choose another copy with Keep This One.

**Why this priority**: A suggestion about something as personal as a date needs an explanation the person
can check.

**Independent Test**: Open each group in the dates demo scenario and assert that a doubtful copy shows its
note and the keeper shows the "no sign of being wrong" line.

**Acceptance Scenarios**:

1. **Given** a group where the copies differ in date reliability, **When** it is opened, **Then** each
   doubtful copy shows the reason and the keeper shows that its date shows no sign of being wrong.
2. **Given** a group where nothing separates the copies (all dates believable, or all doubtful for the
   same reason), **When** it is opened, **Then** no date note is shown.
3. **Given** the suggested copy is removed, **When** the group is updated, **Then** the next best copy is
   suggested by the same rules and notes about removed copies are dropped.

---

### User Story 3 - Every device agrees (Priority: P3)

The baseline photo library holds copies that differ in date, in location, and by a default date. On every
device and simulator the check confirms that the system keeps those dates and locations, and that the
suggested keepers are the expected ones. The date group is built so that the old size rule and the date
rule disagree: it fails if the date rule is removed.

**Why this priority**: The rule depends on metadata the system supplies (the date added to the library,
locations). Only a run on each platform shows that it arrives and is read correctly.

**Independent Test**: `scripts/run-baseline.sh` on a simulator or device; `BaselineHostTests` on the Mac.

**Acceptance Scenarios**:

1. **Given** the baseline library imported through the Photos library, **When** the check runs, **Then**
   capture dates and locations are kept, and the keepers of the three date groups are as expected.
2. **Given** an OS that does not supply the date added to the library (before iOS 26), **When** the check
   runs, **Then** the report says it is unavailable and the rules that need it stay inactive.

---

### Edge Cases

- A scanned family photo with a date the owner set by hand (for example 1965) is not treated as doubtful:
  only the start of 1970 and 1904 (within a day), exactly the start of 2001 (UTC or local midnight), no
  date, and the future are impossible. Real photos from the days around 1 Jan 2001 are not.
- Copies that differ by a few hours from a time zone mistake: dates within an hour of the earliest are the
  same moment; further apart, the earlier is preferred.
- Before iOS 26 the system gives no date added: the saved-moment rule is inactive; the earliest date, the
  default dates, bulk stamps and locations still work.
- Items stored by an earlier version have no date added or location until the next metadata refresh; both
  are unknown, not "none". The first scan after the update refreshes every stored item's metadata, in
  slices of 500, without analyzing anything again.
- Edited versions of a photo are never grouped with the original (001), so edits never compete on date.
- Videos: copies of videos are only grouped with Pro (see spec 004 FR-004a); the same rule would apply. (No Pro version since 2026-10-24, 016: videos are never grouped.)
- All copies doubtful for the same reason (for example every copy dated 1970): the rule falls back to
  resolution, file size and the oldest, as before; different default dates are not ranked against each other.
- Burst frames and the copies of one photo that share a second are not a bulk import.
- Shared timestamps are counted among the photos the scan analyzed and passed to the duplicate detector,
  not among cloud-only photos that were not analyzed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: For a group of duplicate photos the suggested keeper MUST be, in this order: every favorite;
  otherwise the copy with a possible date over one without; then the highest resolution; then a copy that is
  not dated more than a year later than the earliest of the best copies; then the copy whose date and
  details count least against it (FR-003 to FR-006); then a copy not dated more than an hour later than the
  earliest of the copies that tie so far; then the largest file; then the oldest, then a fixed identifier
  order.
- **FR-002**: A date is impossible when it is missing, within a day of the start of 1970 or of 1904,
  exactly the start of 2001 (UTC, or local midnight), or more than a day in the future.
- **FR-003**: A copy's date counts against it when it is the moment the copy was added to the library
  (within two hours) while another copy of the group, whose own date is not a default, has a capture date at
  least a day older than the moment that copy was added, and the first copy's date is more than an hour later.
- **FR-004**: A copy's date counts against it when five or more different photos in the library carry
  exactly the same timestamp, to the second. The copies of the photo itself count once, and a frame of a
  burst is never counted or flagged.
- **FR-005**: A copy's date counts slightly against it when it is exactly midnight; a copy counts slightly
  against it when it is known to have no location while another copy has one.
- **FR-006**: The reasons weigh in this order: saved moment, shared timestamp, missing location, midnight.
- **FR-007**: The choice MUST NOT depend on the order the copies are listed in.
- **FR-008**: iclean MUST NOT change any photo, date, or other metadata. It only suggests. Removal still
  needs the confirmation of 001 FR-012, and one photo of every group is always kept (001 FR-016).
- **FR-009**: When the reasons separate the copies of a group, the group screen MUST show each doubtful copy's
  reason in words with an icon, and say for the suggested copy that its date shows no sign of being wrong.
  Nothing may be conveyed by colour alone.
- **FR-010**: The date added and the location MUST be read from the photo library on the device and stored in
  the local store. No new data leaves the device (Constitution I and II). Delete All Data removes them.
- **FR-011**: Existing stores MUST open unchanged; the new fields start as unknown and fill in when an item's
  metadata is next refreshed, which MUST be written in slices.
- **FR-012**: The baseline photo library MUST contain copies that test FR-001 for a later-dated copy that is
  the larger file, for a missing location, and for a default date, and its report MUST say whether the date
  added is available. The weaker reasons (shared timestamp, midnight, saved moment) are covered by unit tests.

### Key Entities

- **Date Assessment**: for one copy, the reasons its date or details look unreliable.
- **Date Reason**: missing, placeholder, in the future, saved moment, shared timestamp, midnight, stripped
  location.

## Success Criteria *(mandatory)*

- **SC-001**: In the unit tests every scenario of User Story 1 picks the expected keeper, and each check is
  repeated for 20 shuffles of the copies.
- **SC-002**: Keepers do not change in groups where the copies have the same resolution and dates in the same
  hour, or where every date is a default: the existing keeper and duplicate flow tests, which use default
  dates, pass unchanged. Groups with believable dates more than an hour apart intentionally change (Scenario 1).
- **SC-003**: The baseline check passes on the Mac and on the iOS 26.0 and 26.5 simulators, including the three
  date groups and the location check. **Not run yet** on a physical device or on iOS earlier than 26.
- **SC-004**: Reading the two new properties for every item of a 30,000-photo library adds no more than a
  second to the library enumeration on a phone. **Not measured yet**: to be checked on a device. The one-time
  refresh of stored metadata after the update was measured on a Mac at about 7 seconds for 30,000 items written
  in one transaction (research agent, not repeated); the slices make each write short.

## Assumptions

- A copy made later is dated later (saving, importing, downloading, or messaging a photo dates the copy at
  that moment), so among believable dates the earliest is the most probable capture date. A person can defeat
  this by editing a date, which iclean cannot detect; the group screen shows both dates so the person can
  choose.
- iclean reads library information only, not the photo file's own details, so the file's original capture
  date and its name are not used.
- The thresholds (one hour, two hours, one day, one year, five photos) are starting values from reasoning
  about how messaging apps, imports, and exports date copies. They have been checked against constructed
  cases and the baseline library, not against a real library.

## Decisions for you

1. **A believable but later date does not outrank a higher resolution.** Default: yes. A lower resolution
   cannot be restored, while a wrong date can be corrected in Photos in seconds. Only impossible dates
   outrank resolution. If you want any date difference to outrank resolution, say so.
2. **No date repair.** Default: iclean never writes a date into a photo. Copying the probable date onto the
   kept copy would change the library and needs its own decision.
3. **Albums are not a keeper signal.** Default: no. Keeping the copy that sits in the person's albums is a
   possible next rule.

## Changes after review (2026-10-18)

Independent review found and these fixes closed: a default-dated copy made a genuine original look "saved";
burst frames and the copies of one photo inflated the shared-timestamp count; a small doubt could keep a copy
dated decades later (the one-year rule, FR-001); the hour tolerance was a fixed clock hour and is now measured
from the earliest copy; unknown locations were treated as none; different default dates were ranked against
each other; the placeholder check depended on the device calendar; removing the keeper picked the first copy
listed; the first refresh after the update wrote every item in one transaction.
