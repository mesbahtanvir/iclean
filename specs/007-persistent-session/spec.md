# Feature Specification: Persistent Review Session

**Feature Branch**: `007-persistent-session`

**Created**: 2026-10-18

**Status**: Draft

**Input**: User description: "Use a local cache to store scan results on the disk, so that even if I come back after doing mid session it should be able to start from there; it should survive app crashes and closure etc. Also research what is the industry standard for an offline app like this."

**Builds on**: [003-durable-chunked-scan](../003-durable-chunked-scan/spec.md) (scan progress is
already durable), [004-phased-cleaning](../004-phased-cleaning/spec.md) (FR-024, FR-025, SC-004,
SC-005, SC-008: saved results and continuity of choices), [006-date-aware-keepers](../006-date-aware-keepers/spec.md)
(keepers and date notes are part of what is saved), and [001-photo-cleanup](../001-photo-cleanup/spec.md)
(FR-006, FR-012, FR-013, FR-016, FR-018). [005-all-apple-platforms](../005-all-apple-platforms/spec.md)
stays possible (FR-017, FR-018: several windows). This feature **supersedes** the saved-results
details of 004 (its snapshot record, store revision and seen-groups list); see [plan.md](plan.md).

Today the scan survives anything (003), but the review does not. Four gaps remain:

1. Results are rebuilt from every stored photo at each launch and each return to the app. For
   30,000 photos that was measured at about 1.3 s and 570 MB of reading on a fast Mac before the
   first result appears (004 research; a phone is not measured).
2. What the person decided lives only in memory: which photos are ticked, the "Keep This One"
   choices, and which screen is open. A crash, a kill or a restart loses all three. A plain return
   from the background loses the first two as well, because every rebuild resets the ticks to the
   suggestions.
3. Every call to the store runs on the main thread, so a slow store read can freeze the screen.
4. If the store cannot be opened, iclean quietly uses a temporary one, and a failed read looks like
   an empty library ("Your library looks clean").

## User Scenarios & Testing *(mandatory)*

### User Story 1 - I come back and I am where I was, with my choices (Priority: P1)

A person reviews Duplicates for ten minutes. They untick a few photos, tap Keep This One on a few
copies, and open a group. Then iclean crashes, iOS reclaims it, they swipe it away, or the phone
restarts. When they open iclean it shows the screen they were on (if they were away less than a day),
with the same photos ticked and the same copies kept, and it does not scan again.

**Why this priority**: This is the request. Review is the long part of the job, and losing it to a
crash or a swipe makes people stop trusting the app with a big library.

**Independent Test**: With a demo library, tick and untick photos, choose keepers, open a group, wait
three seconds, kill the app, relaunch, and compare the selection, the keepers and the screen with
what they were before the kill.

**Acceptance Scenarios**:

1. **Given** photos ticked or unticked one by one and in bulk, and keepers chosen, **When** the app
   is killed and relaunched, **Then** the same photos are ticked, the same copies are kept, and the
   "Remove N" count is the same. A choice made more than two seconds before the kill is never lost.
2. **Given** the same choices, **When** the app only goes to the background and comes back (no kill,
   even if results were rebuilt meanwhile), **Then** the ticks and keepers are unchanged. Today they
   are reset.
3. **Given** the person was inside a category or a group less than 24 hours ago, **When** they open
   the app after a kill, a crash, a swipe away or a restart, **Then** that same screen is the first
   content they see: no flash of Home, no slide animation, and the list is scrolled to the photo they
   touched last.
4. **Given** more than 24 hours passed, or restoring the screen failed twice in a row, **When** they
   open the app, **Then** Home shows a "Continue reviewing" row (what they were on, how many photos
   are ticked, the space, how long ago) and their ticks and keepers are still restored. Tapping the
   row takes them to the screen.
5. **Given** the group they were on lost some photos while the app was closed, **When** it restores,
   **Then** the group still opens (it is found by its photos). If it no longer exists the category
   opens, and if the category is empty Home opens.
6. **Given** the app was killed with the confirm sheet, the photo viewer, Settings or the system
   delete dialog open, **When** it relaunches, **Then** it shows the category or group screen under
   them. None of those is ever restored, so a stale "Remove 800 photos" sheet is never one tap from
   deleting.
7. **Given** a scan was running when the app was killed, **When** it relaunches, **Then** the scan
   resumes as in 003 and the review choices are intact.
8. **Given** "Always keep" marks, **When** the app is killed at any moment, **Then** they are kept as
   they are today.

---

### User Story 2 - Results appear at once and are never stale or wrong (Priority: P2)

After the first full scan, opening iclean shows the last results straight away, from a saved copy,
instead of rebuilding them from every photo. The saved copy is only shown when it is known to match
what the scan stored and the rules that built it. If anything is in doubt it is thrown away quietly
and rebuilt.

**Why this priority**: A saved copy that can be old or wrong is worse than none. Speed is only worth
having if the person can trust what they see.

**Independent Test**: Relaunch after a full scan with nothing changed and confirm no detection runs
and results show within the targets in SC-004. Then change the library, the rules and the saved bytes
one at a time, and confirm each makes the copy unusable.

**Acceptance Scenarios**:

1. **Given** a finished scan and an unchanged library, **When** the app is relaunched, **Then** the
   category rows and counts appear from the saved copy with no rescan and no rebuild.
2. **Given** photos were deleted, edited or made favorites while the app was closed, **When** it
   opens, **Then** those photos leave the lists within moments, with one dismissible note ("N photos
   were removed or edited since you were here"), and no row appears or moves under the finger.
3. **Given** new photos arrived, **When** the app has checked the library, **Then** the refreshed
   results wait and are applied the next time the person is on Home. An open list never reorders or
   gains rows.
4. **Given** an update changed how duplicates, keepers or dates are judged, or the Pro setting, the
   library access level (Full or Limited), the time zone or the calendar changed, **When** the app
   opens, **Then** the saved copy is not shown and results are rebuilt once. Ticks and keepers are
   kept, because they belong to photos, not to groups.
5. **Given** a saved copy older than 7 days, or one that does not match the store (a scan, a removal
   or an Always keep happened after it), **When** the app opens, **Then** it is not shown.
6. **Given** the saved bytes are damaged, cut short, or written by a newer version, **When** the app
   opens, **Then** they are deleted without a message and results are rebuilt. The person never sees
   an error or an empty list for this.
7. **Given** the app is starting, **When** the first frame is drawn, **Then** it shows the title and
   placeholder rows. It never says "Scan Library" or "Your library looks clean" before the state is
   known. Four states are told apart: opening, building, ready, failed.
8. **Given** the app was killed while sizes were being measured, **When** it restores the saved
   results, **Then** the sizes already measured are shown and measuring continues from there, not
   from zero.

---

### User Story 3 - A stale view can never delete the wrong photo (Priority: P3)

A saved view can be hours or days older than the library. Before anything is removed, iclean checks
the photos about to be removed against the library as it is now, and removes exactly what the
confirmation showed.

**Why this priority**: Removal is the one irreversible-looking action. Saving results makes the view
older, so this protection has to ship with the saved results, not after.

**Independent Test**: Select photos, then delete one, edit one, favorite one, and delete the kept copy
of a group in Photos. Open the confirm sheet and check what it offers, what it drops and what Remove
does.

**Acceptance Scenarios**:

1. **Given** the confirm sheet was just opened, **When** the check against the library is running,
   **Then** the sheet says "Checking selection" and Remove is off until the check returns.
2. **Given** a selected photo is no longer in the library, is a favorite now, or changed since it was
   suggested, **When** the check returns, **Then** it is left out and the sheet says how many were
   left out.
3. **Given** a group whose kept copy has vanished, **When** the check returns, **Then** that whole
   group is left out, so a person can never lose every copy of a photo by accident (001 FR-016).
4. **Given** the sheet is open, **When** results are refreshed or photos change behind it, **Then**
   the sheet, its totals and Remove do not change. Remove removes exactly what the sheet showed.
5. **Given** an old "remove" choice (older than 7 days, or on a photo that changed after it was
   made), **When** the app restores choices, **Then** it is dropped. A "keep" choice is always
   honored.
6. **Given** the app is killed while the system delete dialog is open, **When** it relaunches,
   **Then** the library decides: photos that are gone drop out of the lists, photos that are still
   there stay ticked and need a new confirmation. Nothing is retried on its own.
7. **Given** any removal, **When** it happens, **Then** it still needs the system confirmation and
   goes to Recently Deleted (001 FR-012, FR-013).

---

### User Story 4 - Problems with the saved data are explained, not hidden (Priority: P4)

If the saved data cannot be opened or read, or cannot be written, iclean says so in plain words and
keeps working as well as it can. The person can see what is saved and clear it.

**Why this priority**: Durability is the feature. A failure that looks like "nothing to clean" or
"progress saved" when it is not would be a quiet loss of trust, and the constitution says the person
must see and control what is stored.

**Independent Test**: Damage a copy of the store in each way listed in SC-009 and open it, fill the
disk so scan writes fail, and walk through Settings, Saved on this iPhone.

**Acceptance Scenarios**:

1. **Given** the saved data cannot be opened, **When** the app starts, **Then** Home says "Progress
   won't be saved this time" and the app works with a temporary store. The damaged files are left
   untouched.
2. **Given** a failure to open that is only because the phone has not been unlocked since a restart,
   **When** the app starts, **Then** it waits and opens the store when the data becomes available,
   and does not report damage.
3. **Given** a read from the store fails, **When** results would be shown, **Then** a load failure is
   shown, never "Your library looks clean".
4. **Given** a scan cannot save three checkpoints in a row, **When** the third fails, **Then** the
   scan pauses with "Couldn't save progress" and a way to resume once space is freed. It never keeps
   running with progress that is not saved.
5. **Given** the saved data is unreadable, **When** the person opens Settings, **Then** "Delete saved
   data" is offered. After a confirmation it removes the store and its two companion files together,
   and iclean starts from an empty library state.
6. **Given** Settings, **When** the person opens "Saved on this iPhone", **Then** it shows what is
   saved (saved results: size and when built; review progress: counts) and offers "Clear saved
   results" (safe, they rebuild) and "Reset review choices". Delete All Data covers all of it.
7. **Given** a choice was made a moment ago, **When** the person taps Delete All Data and then sends
   the app to the background, **Then** nothing is written back: after a relaunch no choice, position
   or saved result exists.

---

### Edge Cases

- **Kill during a save**: each save is one all-or-nothing change. The old copy or the new copy
  exists, never a mix. Choices made in the last second or two before the kill may be missing; nothing
  older is.
- **Power loss or kernel panic**: the store comes back in an earlier consistent state (results,
  choices and scan progress together). The last few seconds of choices may be missing. A committed
  save is lost only in this case, not on a crash or a kill (research R3).
- **Library access changed while closed** (Full to Limited): the saved copy is not shown, because the
  access level is part of what it was built for. The Access screen from 001 is shown when access is
  removed, and saved data stays on the phone until the person deletes it.
- **Photos that cannot be fetched** (deleted, hidden, in Recently Deleted, outside a Limited
  selection): all mean "leave the lists". iclean never deletes anything from the library because of
  that.
- **Time zone or calendar change** (travel): the saved copy is rebuilt once, because dates and
  midnight checks depend on them (006).
- **A photo ticked, then favorited elsewhere**: the old "remove" choice is dropped. A photo that has
  since become the kept copy is not removable and is not ticked.
- **Select All on a large category**: one save of about 1 to 2 MB at 20,000 photos before compression
  (estimate); never one save per photo.
- **Several windows** (005): each window keeps its own place while it runs. Only the last saved place
  is restored at launch, and windows never mirror each other's navigation.
- **Update from an older version**: the first launch has no saved copy, so results are built once.
  Choices start empty. Existing stores open unchanged (two tables are added, nothing else changes).
- **Going back to an older version**: saved results, choices and place written by a newer version are
  ignored or dropped by the older one. Accepted, because it only happens in testing builds.
- **Scan Again**: review choices are kept; new photos get the suggested ticks.
- **Disk full when saving choices**: the choices stay on screen and the save is retried at the next
  save point. v1 does not announce it (see Assumptions).
- **A kill while the app was restoring a screen**: the attempt is counted. After two attempts that
  never ended cleanly iclean stops going there on its own and shows the Continue row.

## Requirements *(mandatory)*

### Functional Requirements

**Review choices**

- **FR-001**: The ticks, bulk selections and "Keep This One" choices MUST be saved on the phone and
  MUST survive a kill, a crash, a restart and closing the app. They MUST be applied again by every
  publish of results (launch, return to the app, a finished scan, a rebuild), so none of those
  resets them.
- **FR-002**: Choices MUST be saved by photo, never by group, because a group's identity changes when
  one photo leaves it. Only differences from the suggestions are saved. Ticking a photo back to its
  suggested state removes the saved choice. Choosing a keeper removes any "remove" choice for that
  photo.
- **FR-003**: A saved "remove" choice MUST be applied only if the photo is still a removable member
  of a group, is not a favorite, is not kept by an Always keep mark, has not changed since the choice
  was made, and the choice is not older than 7 days. A saved "keep" choice MUST always be honored,
  and is forgotten after 180 days or when the photo is removed. A keeper choice MUST be dropped when
  the photo is gone or is not in a group that has a keeper.
- **FR-004**: Choices MUST be written after 500 ms without a further change, and no later than 2 s
  after the first unsaved change of a burst. They MUST also be written when the app becomes inactive
  or goes to the background (with extra background time requested at once), when the confirm sheet
  opens, and before a removal. Saving MUST NOT depend on a termination callback or on the system's
  scene storage.
- **FR-005**: The screen the person is on MUST be saved as a category, and a group identified by up
  to three of its photos. The confirm sheet, the photo viewer, Settings, and the delete dialog MUST
  NOT be saved or restored.
- **FR-006**: A saved screen MUST be restored on its own when it was saved less than 24 hours ago and
  fewer than two earlier restores ended without a clean exit. Otherwise Home MUST show a "Continue
  reviewing" row. Going to Home on purpose clears the saved screen, and "Start fresh" (after a
  confirmation) clears it and the choices, but not scan data.
- **FR-007**: A restore MUST show the destination as the first content frame, without a Home flash or
  a push animation, and scroll to the last photo touched. A saved route that no longer fits MUST be
  shortened to the nearest screen that does.

**Saved results**

- **FR-008**: The results MUST be saved on the phone as a copy that can be thrown away. It MUST be
  shown only when it is intact, written by the same version of the rules, matches the store and is
  less than 7 days old. Otherwise it MUST be deleted without a message and rebuilt.
- **FR-009**: The store MUST keep a counter that only goes up and is never reset, not even by Delete
  All Data. It MUST move, in the same all-or-nothing step as the write, whenever a write changes what
  results are built from: a new photo, a photo whose results-relevant details changed, a removal, an
  Always keep change, and a size going from missing or estimated to measured (once per batch). It
  MUST NOT move for scan bookkeeping.
- **FR-010**: What the copy was built for MUST include the version of the rules (a number a person
  raises when detection, thresholds, keeper rules or date rules change, checked by a test over the
  baseline library), the set of detectors, the Pro settings, the library access level, and the time
  zone and calendar.
- **FR-011**: The copy MUST hold only the photos that appear in groups, without any image-derived
  data (no thumbprints, feature prints or hashes). It MUST NOT hold the person's choices.
- **FR-012**: The first frame MUST be the title and placeholders by launch phase. The launch read
  MUST NOT load stored photos (only a count); restoring results reads at most the sizes of the
  displayed photos. One read loads everything the launch needs; one publish applies results, choices
  and the saved screen.
- **FR-013**: After the first publish the app MUST check the displayed photos against the library and
  run the quick check. If the store changed, a rebuild MUST follow off the main thread. Its result
  MUST be applied at once if the person is on Home with nothing open over it, and otherwise at their
  next visit to Home. It MUST NOT be applied while a sheet is open, and MUST NOT reorder or add rows
  to a list under the finger.
  (Built 2026-10-18: the check of displayed photos runs once at launch, before the saved screen is
  put back, through `PhotoLibrary.stamps(forIDs:)`; photos deleted or changed are dropped from the
  lists and the store and a rebuild follows. The inline note "N photos were removed or edited" is not
  built yet; the confirm-time check still stops anything stale from being removed.)
- **FR-014**: A removal or an Always keep MUST move the counter and MUST NOT save a patched copy. The
  lists update in place for immediate feedback, then a normal rebuild runs and its result is saved,
  but only if the store has not moved since it was built.
- **FR-015**: Sizes already measured, or estimated, MUST be read from the store and shown on restored
  results, so the measuring pass does not repeat that work.

**Removal safety**

- **FR-016**: When the confirm sheet opens, iclean MUST build a fixed plan (the photos, the groups
  they belong to, and totals per category) after checking each photo against the library. Photos that
  are no longer in the library, are favorites now, or changed since they were suggested MUST be left
  out, and so MUST any group whose kept copy has vanished (unless the person knowingly chose to remove
  the whole group under 001 FR-016).
- **FR-017**: Remove MUST execute exactly that plan. Changes to results or photos after the sheet
  opened MUST NOT change an open plan. The sheet MUST say "Checking selection" until the check
  returns.
- **FR-018**: Removal MUST still need the system confirmation and MUST go to Recently Deleted
  (001 FR-012, FR-013).

**Failure handling**

- **FR-019**: The store MUST be opened and used off the main thread, and the first frame MUST NOT wait
  for it. No store method may run on the main thread.
- **FR-020**: A failure to open the store MUST NOT become an empty or clean state. Home MUST say
  "Progress won't be saved this time" and the app MUST run on a temporary store. The damaged files
  MUST be left untouched. A failure that is only data not yet available after a restart MUST be
  waited out.
- **FR-021**: A failed read MUST be shown as a load failure, never as an empty library.
- **FR-022**: After three failures in a row to save scan progress (checkpoints) the scan MUST pause
  with the reason "Couldn't save progress".

- **FR-023**: Settings MUST offer "Delete saved data" when the store could not be opened or read. It
  MUST need a confirmation and MUST remove the store and its two companion files together.
- **FR-024**: Saved results, choices or a saved screen written in a format this version does not know
  MUST be ignored, never misread.

**Control and data**

- **FR-025**: Settings MUST have one constant row, "Saved on this iPhone", that opens its own screen
  showing what is saved (saved results: size and when built; review progress: counts), with "Clear
  saved results", "Reset review choices", and the existing Delete All Data.
- **FR-026**: Delete All Data MUST stop pending saves, clear the choices, saved screen and pending
  results held in memory, delete every saved row, and refuse any save that was started before it. A
  save MUST NOT bring anything back.
- **FR-027**: Existing stores MUST open unchanged: two new tables are added and nothing existing is
  altered (003 R6).
- **FR-028**: No saved row or log line MAY contain image data. Logs MUST NOT contain photo
  identifiers. Nothing leaves the device (Constitution I and II).

### Key Entities

- **Saved Results**: the slim copy of what the screens show (categories, groups, the photos in groups,
  notes), with what it was built for and which store state it matches. It can always be deleted.
- **Review Choices**: the person's ticks and keeper choices as differences from the suggestions, each
  with the time it was made.
- **Saved Place**: the screens the person was on, the last photo touched, and a count of unfinished
  restores.
- **Store Counter** (results revision): a number that only goes up, moved by writes that change what
  results are built from.
- **Removal Plan**: the fixed list of photos and totals the confirm sheet shows and Remove executes.
- **Load State**: opening, building, ready or failed, so the first frame never claims more than is
  known.

### Data & Network

- **Data touched**: photo identifiers, the person's choices and the time of each, a navigation
  breadcrumb, and a derived copy of results (identifiers, album names and metadata that the store
  already holds). No images or thumbnails are written.
- **Where stored**: the existing local store (Application Support, excluded from backup, the default
  file protection that allows writes after first unlock). Each row can be deleted on its own, and
  Delete All Data removes all of them.
- **Network**: none. No new framework outside Apple's system frameworks (Constitution I to V).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In 100 runs that kill a helper process at a random moment while it writes scan
  checkpoints and review choices, every run reopens with a store that passes the integrity check, the
  choices equal the last or the next committed version (never a mix), the scan guarantees from 003
  hold, and the saved results are either absent or pass the checks in FR-008.
- **SC-002**: In 20 consecutive kill-and-relaunch runs for each of selection, keeper choice and saved
  screen, the restored state equals the state at the last save point in every run (kills made at
  least 3 seconds after the last change).
- **SC-003**: A choice made more than 2 seconds before a kill is never lost. The most that is lost is
  what was changed in the last 2 seconds plus the time of one write.
- **SC-004**: Relaunch after a 30,000-photo scan with an unchanged library shows a usable Home within
  1 second and the last results within 2 seconds (004 SC-004, reference phone, Release build).
  **Target, not measured on a phone yet.** In 100% of automated unchanged-relaunch tests, no detector
  runs and the stored photos are not loaded before the first publish (only their sizes are read).
- **SC-005**: A saved copy is shown in 0% of the table-test cases where its counter, version, rules,
  checksum, counts or age does not match, and every method that writes to the store appears in the
  table that states whether it moves the counter (100% coverage).
- **SC-006**: In 100% of test runs a return from the background leaves ticks and keepers unchanged
  (today: 0%).
- **SC-007**: In 100% of removal-check tests (photo deleted, edited, favorited, burst member present,
  kept copy gone) the removed set equals the set the sheet showed, and no photo that failed the check
  is removed.
- **SC-008**: In 100% of kill-inside-the-sheet tests the relaunch lands on a screen that is not a
  sheet, viewer or Settings.
- **SC-009**: For each damage case (zero the header, cut the file, flip a byte in a data page, delete
  the companion log file, open a store from a newer version) there is no crash and no "Your library
  looks clean", and the outcome is the one listed in [quickstart.md](quickstart.md) in 100% of runs.
- **SC-010**: In 100% of cold-start UI tests no frame before the state is known contains "Scan
  Library" or "Your library looks clean".
- **SC-011**: In 100% of runs of "choose, Delete All Data, send to background, relaunch" (with and
  without a pending save) no choice, saved screen or saved result exists afterwards.
- **SC-012**: Zero store calls run on the main thread across the whole test suite (an assertion hook
  fails the run otherwise).
- **SC-013**: Saved results at 30,000 photos stay under 3 MB and restoring them uses less memory than
  rebuilding (about 150 MB less is expected). **Estimates, not measured; to be measured in a Release
  build.**

## Assumptions

- "Cache" in the request means saved results plus saved review state, kept in the app's own local
  store. Scan progress itself is already saved (003) and is unchanged.
- Everything runs on the device. iclean has no account, server or sync (Constitution I and II), and
  photo identifiers are only valid on this device, so a new phone correctly starts empty.
- The reference library is 30,000 photos. Every phone figure here is a target. The measurements
  quoted in the research are from a Mac or the simulator, and the device is not verified.
- The store survives a crash, a kill and a force-quit after each save. It can lose its last commits
  only on a power loss or kernel panic, and then it returns to an earlier consistent state (research
  R3, verified on a Mac and the simulator, not on a device).
- The quick check on every launch and return still reads every stored photo to compare it with the
  library, so peak memory during that check is not lowered by this feature. Reading only what the
  planner needs stays with 004 (FR-025). This feature moves that work off the first frame and off
  the main thread.
- A failed save of review choices is retried at the next save point and is not announced in v1. The
  choices stay on screen.
- iclean does not change any photo or its metadata (006 FR-008). Photos' Recently Deleted cannot be
  listed by an app, so an unfetchable photo is simply "gone from the lists".
- "Left off" is judged by the clock time of the last save. A person who changes the phone clock
  backwards can make a saved screen look newer; this only affects whether it is restored on its own.

## Decisions for you

1. **Auto-restore window: 24 hours.** Default: within 24 hours of the last save iclean goes back to
   the screen by itself; after that, and after two failed restores, Home shows the Continue row.
   Apple discards its own screen restoration after a force-quit as a safety precaution, so going back
   by ourselves is a choice. Setting the window to 0 gives the row only.
2. **Expiry of saved results and "remove" choices: 7 days.** Default: after 7 days the saved results
   are rebuilt (one background build, about 2 s on a Mac), and an old tick on a photo is forgotten, so
   a forgotten selection can never sit one tap from deletion.
3. **Expiry of "keep" choices: 180 days.** Default: a keep choice is honored until removed or until
   180 days pass.
4. **Continue reviewing row.** Default: shown when a screen was saved but not restored on its own,
   with a "Start fresh" action behind a confirmation. If you would rather never show it, the saved
   screen is simply dropped when it is not restored.
5. **Damaged saved data is never moved or deleted automatically.** Default: iclean says so and runs
   without saving; only you can delete it, with "Delete saved data". Moving it aside automatically
   (and starting fresh) risks losing Always keep marks and hours of scanning on a misjudged error.
6. **Export of your data in an open format (constitution IV) is not part of this feature.** Default:
   not built here. No export exists today for any iclean data; this feature adds more data to that
   gap and records it as a follow-up in [plan.md](plan.md).

## Not in this feature

- A photo library change cursor (PHPersistentChangeToken) to avoid re-reading the library. The design
  is recorded in [research.md](research.md) R13, to be built only if the foreground check costs more
  than about 1.5 s or 300 MB at 30,000 photos on the phone.
- Adopting versioned SwiftData schemas (this change only adds two tables).
- A JSON copy of Always keep marks, or salvaging a damaged store.
- Forcing a database flush to disk with raw SQLite calls (unsupported against a store SwiftData owns,
  and it protects only against power loss).
- Cross-device identifiers (PHCloudIdentifier), thumbnails on disk, an integrity check at every
  launch, and the incremental results engine of 004 S5.
- Restoring the photo viewer, Settings, or any sheet.
- A slimmer read for the quick check's comparison with the library (004 FR-025), and a screen to review
  or undo single Always keep marks.
- Export of keep marks and choices in an open format (Decision 6).
- A write-ahead removal journal (covered by the check at confirm time and the check at launch).
