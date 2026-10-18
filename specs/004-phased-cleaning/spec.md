# Feature Specification: Phased Cleaning for Large Libraries

**Feature Branch**: `004-phased-cleaning`

**Created**: 2026-10-18

**Status**: Draft

**Input**: User description: "Some people might have a library as big as 30K photos, so
running all the analysis at the beginning might not be ideal, can we plan phased cleaning?"
and "work appropriately based on the device."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) (FR-005, FR-005a, FR-006,
FR-007, FR-010a, SC-001), [002-background-scan-progress](../002-background-scan-progress/spec.md)
(pause reasons, thermal pause) and [003-durable-chunked-scan](../003-durable-chunked-scan/spec.md)
(FR-015: the job model allows other kinds of pieces). Today one scan analyzes every photo
completely and shows nothing until it ends, then rebuilds all results from every stored
item at each launch. At 30,000 photos that is about 25 minutes before the first result at
the 20 items per second the first spec assumes, and a results build that holds hundreds of
megabytes. This feature splits cleaning into steps ordered by value for cost, lets people
review as results appear, fits the pace to the device, and keeps launch and memory bounded.
Spec [005](../005-all-apple-platforms/spec.md) covers the other Apple platforms; this one is
written so its policy applies to all of them.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The easy wins show up in seconds (Priority: P1)

A user with 30,000 photos grants access. Before any photo has been opened for analysis, Home
already lists their screenshots and their largest videos, with counts and the space they
take. They can review and remove them straight away while the rest of the library is still
waiting to be checked.

**Why this priority**: These two categories need no image analysis at all, yet today they
wait behind the slowest part of the scan. For many people they are the biggest cleanup.

**Independent Test**: Open a library of 30,000 demo items whose photo analysis is slow.
Assert that Screenshots and Large Videos are listed, with counts, before the first piece of
photo analysis finishes, and that removing them asks for the usual confirmation.

**Acceptance Scenarios**:

1. **Given** access was just granted on a library of 30,000 items, **When** Home appears,
   **Then** Screenshots (all of them) and Large Videos (the 50 largest) are listed within
   10 seconds, with counts and space, and nothing has been analyzed yet.
2. **Given** a video's real file size has not been measured yet, **When** it is listed,
   **Then** its size is shown as an estimate ("about 480 MB") and is replaced by the real
   size when measured, without moving the video in the list by more than its new rank.
3. **Given** the quick results are shown, **When** the user removes some of them, **Then**
   the usual confirmation appears first and the photos go to Recently Deleted.
4. **Given** later steps run, **When** they finish, **Then** no screenshot has moved to
   another category and no listed screenshot has disappeared.

---

### User Story 2 - Review while the scan continues (Priority: P2)

The user taps Start. Newest photos are checked first, in blocks. After the first small block
(about 30 seconds on a typical phone) the duplicates and blurry photos found so far are
ready to review, labeled "found so far, checked 500 of 24,700". They open Duplicates and
start cleaning while the scan keeps going. A list they have open never shuffles under them;
new finds wait behind a "12 new" prompt. Their choices (which photo to keep, what is
unselected, what they removed) are still there after every update. When the last step ends,
the results are the same as a one-shot scan would have produced.

**Why this priority**: This is what makes a 25-minute scan tolerable: the wait stops being
dead time. It is also the hardest part to get right without surprising people.

**Independent Test**: Scan a demo library in newest-first blocks with a script that opens a
category, toggles selections, changes a keeper, and removes a group between block updates.
Assert that nothing the user did is undone, that the open list does not change until
refreshed, and that the final results equal a one-shot scan of the same library.

**Acceptance Scenarios**:

1. **Given** a scan has finished its first block, **When** the user opens Duplicates,
   **Then** the groups found so far are listed, and the row says how much of the library
   has been checked.
2. **Given** the user has Duplicates open, **When** another block finishes and finds more
   groups, **Then** the open list does not change; a prompt says how many new groups are
   available and shows them when tapped.
3. **Given** the user unselected a photo, kept another, or removed a group, **When** the
   next update arrives, **Then** the photo is still unselected, the keeper unchanged
   (unless it left the group), and the removed photos are never suggested again.
4. **Given** a category has no finds yet but a step that feeds it has not finished,
   **When** Home shows it, **Then** it says it is still being checked, never "Your library
   looks clean".
5. **Given** all steps have finished, **When** the results are compared with a one-shot scan
   of the same library, **Then** the groups, keepers, and categories are the same.

---

### User Story 3 - The pace fits the device and the moment (Priority: P3)

On a recent phone the scan runs at full speed and finishes everything in one go. On an older
phone with little memory it checks copies and blur first and offers similar shots "when
charging, or run now". When the phone gets warm the scan slows down before it has to stop.
In Low Power Mode it does only what the user asks for. Home says in plain words what is
running and what waits, with a time range that updates when conditions change.

**Why this priority**: Without it a 30,000-photo library either overheats a phone or crawls
on a fast one. It builds on the steps of the first two stories.

**Independent Test**: Run the scan against injected device and condition profiles (3 GB phone,
recent phone, Mac on battery, desktop Mac, warm, Low Power Mode, low battery, memory
warning). Assert the width, block size, and steps that run automatically for each, that no
condition ever makes the scan run more than before, and that the status text matches.

**Acceptance Scenarios**:

1. **Given** a device with limited memory or no Neural Engine, **When** the scan reaches the
   similar-shots step, **Then** it waits for external power or the user's "Run now", says
   so, and the earlier steps' results stay reviewable.
2. **Given** the phone becomes warm (fair), **When** the scan is running, **Then** it halves
   its parallel work without stopping; at serious or critical it pauses as in spec 002 and
   resumes after cooling down.
3. **Given** Low Power Mode is on, **When** the user taps Start, **Then** only the quick
   results and the photo pass run, the later steps show "Paused: Low Power Mode" with a
   "Run now" button, and nothing starts on its own.
4. **Given** battery is under 20% and the device is not charging, **When** a scan is
   running, **Then** it pauses everything except the quick results, says why, and continues
   when power is connected or the user taps "Run now".
5. **Given** the system sends a memory warning, **When** the scan is running, **Then** it
   halves its parallel work for a while, frees its caches, and is never ended by the system
   for memory.
6. **Given** the user chose "Gentle" or "Full speed" in Settings, **When** the scan runs,
   **Then** the choice moves the pace one step down or up, but never overrides a serious
   thermal state or a critical memory state.

---

### User Story 4 - A 30,000-photo library stays fast on every launch (Priority: P4)

A user with a very large library opens iclean the next day. Home is usable in about a second
and the last results are already there. The app has not re-examined all 30,000 photos in
memory to show them. Odd libraries (thousands of photos stamped within the same minute after
an import, many near-identical dark photos) do not make anything take minutes.

**Why this priority**: The research measured the cost of the current design at launch and
found it to be memory first and, in unoptimized builds, time. It matters most to the people
with the biggest libraries.

**Independent Test**: With a 30,000-item store and a Release build, relaunch and measure time
to a usable Home and peak memory; repeat with 3,000 items stamped within one minute and with
15% of photos sharing near-identical fingerprints.

**Acceptance Scenarios**:

1. **Given** a finished scan of 30,000 photos, **When** the app is relaunched, **Then**
   Home is usable within 1 second and the last results are shown within 2 seconds, without
   re-running detection over every item.
2. **Given** photos were added or removed since, **When** Home appears, **Then** the saved
   results are shown at once and refreshed in the background only if something changed.
3. **Given** 3,000 photos with capture times within the same minute, **When** results are
   built, **Then** the build finishes within 5 seconds on the reference Mac in a Release
   build (the measured time today is 43 seconds).
4. **Given** 15% of photos have near-identical fingerprints, **When** results are built,
   **Then** the build finishes in under 3 times the time for ordinary data.
5. **Given** a library of 100,000 items, **When** it is scanned and reviewed, **Then** every
   step works and times grow roughly in proportion to the size.

---

### User Story 5 - Stop after a step and continue later (Priority: P5)

A user is happy with the duplicates and blurry photos found, and does not want the phone
busy any longer. They tap "Stop after this step". The current piece finishes, later steps are
marked "not run", and Home offers "Continue finding more (about 6 min)". Next week they tap
it and only the missing work is done.

**Why this priority**: It gives people an honest way to stop early without losing anything,
and it makes the plan understandable. It adds little on top of stories 1 to 3.

**Independent Test**: Stop after each step in turn on a demo library, relaunch, continue,
and assert that only unchecked work runs and the final results equal a one-shot scan.

**Acceptance Scenarios**:

1. **Given** a step is running, **When** the user taps "Stop after this step", **Then** the
   in-flight piece finishes and is saved, the later steps show "Not run", and the results
   found so far stay reviewable.
2. **Given** steps were not run, **When** the user taps "Continue finding more", **Then**
   only the missing work runs, and the time estimate shown covers only that work.
3. **Given** the user pauses, stops, or the app is ended during any step, **When** they come
   back, **Then** Resume works exactly as in specs 001 to 003.

---

### Edge Cases

- Photos are added, edited or removed while steps run: items that left the library are
  skipped without counting as failures; new and edited ones become new pieces (003 FR-011).
- The user removes photos while a step is running: running steps skip them, and the saved
  results update without the user's open list changing.
- A photo exists only in iCloud (Optimize Storage): it is checked from the local preview if
  there is one, counted as "not fully checked" otherwise, and the app never uses the network
  (001 FR-014, FR-017). Results from a lower-quality preview never count as certain.
- The device is plugged in when the scan starts and unplugged during it: steps that need
  power wait at the next piece boundary and say so.
- The user starts a scan, the battery dies, and the app is opened a day later: 003 resume
  applies; the plan continues at the first unfinished piece of the first unfinished step.
- Photos have no capture date or thousands share one timestamp (an import): they are handled
  in fixed-size groups in creation order, and similar-shot matching stays bounded.
- A library is at Limited access: the plan is built from the photos the app can see, and
  says "checked N of M" for that set.
- An existing store from before this feature: items analyzed by the old single pass count
  as fully analyzed; nothing is scanned again because of this update.
- The same scan is started on an iPad and an iPhone with one iCloud library: each device
  has its own store and runs its own plan (stored identifiers are device-local).

## Requirements *(mandatory)*

### Functional Requirements

**Quick results**

- **FR-001**: Right after access is granted, and each time the app is opened, the app MUST
  list screenshots and the largest videos using library information only, without opening
  any photo for analysis, within 10 seconds on a library of 30,000 items.
- **FR-002**: These results MUST be reviewable and removable at once, with the usual
  confirmation (001 FR-012). A size that has not been measured yet MUST be shown as an
  estimate.
- **FR-003**: Screenshots listed by this step are final: later steps MUST NOT move them to
  another category or remove them from the list. This amends 001 FR-002 and FR-004a, which
  let a duplicate screenshot appear under Duplicates.

**Steps and order**

- **FR-004**: A full cleaning MUST run as ordered steps: (1) Quick wins, (2) Photos
  (duplicates, blur, and similar shots when the device allows), (3) Similar shots (only when
  the device defers it from step 2), (4) Best-shot refinement. Each step MUST have its own
  progress and result milestone.
- **FR-004a**: In the free app, videos MUST NOT be analyzed: no video frame is opened, hashed,
  or compared, and there is no Duplicate Videos category. Large Videos stays, because it ranks
  videos by file size and needs no analysis. Video analysis and the Duplicate Videos category
  are a Pro feature (a one-time $2 purchase) that is not part of this feature's work and is not
  built (Decision 7). This amends 001 FR-004b and the video half of FR-008.
- **FR-005**: Photos MUST be processed newest first, in blocks. The first block MUST be small
  (about 500 photos) so that the first results appear within about 30 seconds on a typical
  phone, and later blocks MUST grow to a size set by the device.
- **FR-006**: Costly signals MUST be computed only where they can change the outcome: the
  similar-shot signal only for photos with another photo within 60 seconds, and best-shot
  refinement only for groups where it can change the pick.
- **FR-007**: After the user taps Start, later steps MUST follow on their own unless the
  device or its conditions make them wait (FR-017 to FR-020). Nothing MUST start while the
  user has not started a scan, apart from the continuation 002 already allows (001 FR-005a).
- **FR-008**: Every step MUST be made of the durable pieces from 003, so that pause, stop,
  retry, crash recovery, and resume behave the same in every step.

**Results while running**

- **FR-009**: Results MUST be published at the end of every block and step. Each category
  row MUST show "found so far" and "checked N of M" until its steps are done.
- **FR-010**: A list the user has open MUST NOT reorder, lose, or gain items. New results MUST
  appear behind a prompt that shows the count, or on the next visit.
- **FR-011**: The user's choices MUST survive every update: selections, keep marks, removals,
  and items they unselected. An item that was removed or marked keep MUST NOT be suggested
  again by a later update.
- **FR-012**: A keeper the user has seen MUST NOT change in a later update unless that photo
  has left the group.
- **FR-013**: A category MUST NOT claim "looks clean" or show an empty state until every step
  that feeds it has finished or been stopped by the user.
- **FR-014**: The final results after all steps MUST equal the results of a one-shot scan of
  the same library, apart from the amendment in FR-003.

**Pace**

- **FR-015**: The app MUST choose how many items it works on at once, the block size, and
  which steps run on their own from the device (memory, cores, form factor, whether a Neural
  Engine is present) and from conditions (thermal state, Low Power Mode, charging and
  battery, memory pressure, and whether the user is reviewing). The device MUST NOT be named
  to the user as a tier.
- **FR-016**: At a fair thermal state the app MUST halve its parallel work. At serious or
  critical it MUST pause and resume as spec 002 says. This amends 002, which only paused.
- **FR-017**: In Low Power Mode the app MUST cap its parallel work and MUST NOT start the
  similar-shots and refinement steps on its own; the user MAY start them with "Run now".
- **FR-018**: On a device with limited memory or without a Neural Engine, the similar-shots
  step MUST wait for external power or the user's "Run now".
- **FR-019**: On battery below 20% the app MUST pause everything except the quick results,
  say why, and continue on power or on "Run now".
- **FR-020**: A memory warning MUST halve the parallel work for a period and release caches;
  repeated warnings MUST lower the pace for the rest of the session.
- **FR-021**: The app MUST say, in words, what runs now and what waits, with time ranges that
  update when conditions change, using the device's name for itself (iPhone, iPad, Mac).
- **FR-022**: Settings MUST offer Automatic, Gentle, and Full speed. Full speed ignores the
  power and Low Power Mode rules only; serious thermal and critical memory always win.
- **FR-023**: Preview size and the analysis recipe MUST NOT depend on the device or its
  conditions, so saved fingerprints stay comparable across devices and pace changes.

**Scale**

- **FR-024**: On launch the app MUST show the last results from a saved snapshot without
  re-running detection over all items, and refresh in the background only if the stored items
  changed.
- **FR-025**: Building or refreshing results MUST use memory in proportion to what detection
  needs, not to the whole stored record of every item.
- **FR-026**: Detection cost MUST be bounded for any capture-time or fingerprint
  distribution. Thousands of photos in one minute, or many near-identical photos, MUST NOT
  make results take more than a small multiple of the normal time.
- **FR-027**: Nothing on the launch path MUST grow with library size on the main thread, and
  no feature MUST be quadratic in library size for ordinary data.

**Control and data**

- **FR-028**: "Stop after this step" MUST end the current step cleanly, skip the rest, and
  offer "Continue finding more", which MUST do only the missing work.
- **FR-029**: Removal MUST work while steps run; running steps MUST skip removed items.
- **FR-030**: Existing stores MUST open unchanged, and items analyzed before this feature MUST
  count as fully analyzed.
- **FR-031**: Saved plan, step, and snapshot records MUST contain only identifiers, counts,
  and states. No data leaves the device (Constitution I and II). Delete All Data MUST remove
  them (001 FR-018).

### Key Entities

- **Cleaning Plan**: the ordered steps of one scan, each with a state (waiting, running,
  paused with a reason, done, not run) and progress. Replaces the single bar of today.
- **Step**: one kind of work over a set of items: quick wins, photos, similar shots,
  best-shot refinement. Only photos are analyzed.
- **Block**: a group of photos, newest first, after which results are published.
- **Device Profile and Conditions**: what the device is and what it is doing now. Internal;
  they decide pace and are never shown by name.
- **Results Snapshot**: the last published results, saved so launch does not rebuild them.

## Success Criteria *(mandatory)*

### Measurable Outcomes

Times marked "reference phone" are for a phone of the class the first spec targets (about
20 items per second), measured on a real device with the baseline library harness.

- **SC-001**: Screenshots and Large Videos are listed within 10 seconds of granting access on
  a library of 30,000 items (reference phone, Release build).
- **SC-002**: The first duplicate or blurry results are reviewable within 60 seconds of
  tapping Start (reference phone).
- **SC-003**: A first full scan of 10,000 photos still finishes in under 10 minutes, as in
  001 SC-001. A scan of 30,000 photos finishes in under 40 minutes at the reference rate.
- **SC-004**: Relaunch after a 30,000-photo scan shows a usable Home within 1 second and the
  last results within 2 seconds (reference phone, Release build).
- **SC-005**: Peak memory while building or refreshing results for 30,000 photos stays under
  200 MB (measured 853 MB peak today on a Mac with a Release build).
- **SC-006**: Building results for 3,000 photos stamped within one minute takes under 5
  seconds (measured 43 seconds today), and for a library where 15% of fingerprints are
  near-identical under 3 times the ordinary time.
- **SC-007**: In 100% of table-driven tests over thermal, Low Power Mode, power, memory, and
  device profiles, a worse condition never raises the width or turns on a step.
- **SC-008**: In 100% of runs that change selections, keepers, and removals between updates,
  the user's choices survive, and the final results equal a one-shot scan.
- **SC-009**: In 100 random kills across steps and blocks, every run completes after Resume,
  and at most one piece is repeated per kill (003 SC-001 holds in every step).

## Assumptions

- The 20 items per second of 001 stays the design floor for a standard phone. Every other
  speed in this spec is an estimate until measured on devices; the plan's first task is to
  measure it with the baseline library harness.
- New scans go newest first. A job already started under 003 keeps its order.
- Previews stay at the current size for every device (FR-023). A smaller preview for the
  first pass is a possible later optimization that needs its own accuracy check.
- This feature does not add unattended background analysis (BGProcessingTask while charging).
  001 FR-005a stays as written: scanning happens only after the user starts it.
- Camera-picked burst keepers and a "likely copies" category are not part of this feature.
- The policy (steps, pace, snapshot) is platform-neutral. Numbers use the iPhone as the
  reference; spec 005 adds platform specifics.
- Everything in 001 to 003 about privacy, confirmation, and durability applies unchanged.
- In the free app, videos are outside analysis. The Duplicate Videos category, the video
  poster-frame analysis, and the video keeper rule are Pro only (a one-time $2 purchase, not
  built; see FR-004a), and Large Videos works from file sizes alone. In the free app, stores
  that already hold video analysis keep it unused.

## Decisions for you

Each has a default the plan follows unless you say otherwise.

1. **Screenshots are final after Quick wins** (FR-003). Default: yes. It saves the work of
   analyzing about 7% of photos and removes a duplicate-screenshot edge case, at the cost
   that a group of identical screenshots is all selected for removal, as every screenshot is.
2. **Newest first** for new scans. Default: yes.
3. **Fair thermal state halves the pace** (FR-016). Default: yes. The research also
   suggested running one-wide at serious for up to two minutes; the plan does not adopt it
   because it is untested.
4. **No unattended background analysis** in this feature. Default: none, as above.
5. **Camera-picked burst keepers** as a metadata category. Default: not in this feature.
6. **Video analysis is a Pro feature (one-time $2).** Free: no video analysis, Large Videos
   by size. Default: as the owner decided.
7. **The Pro purchase needs a constitution decision before it is built.** Principle II says no
   remote configuration, feature flags or license checks, and Principle V says network
   permissions are not requested. A one-time in-app purchase is bought through the system's
   purchase sheet and checked on the device by the system's purchase framework; the app opens
   no connection of its own. Default: build nothing until you approve that reading or amend
   the constitution. The Mac sandbox and the no-network test plan must then treat the system's
   purchase traffic as not the app's.
