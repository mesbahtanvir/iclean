# Feature Specification: Scan Progress Outside the App

**Feature Branch**: `002-background-scan-progress`

**Created**: 2026-10-17

**Status**: Draft

**Input**: User description: "Scan progress in the Dynamic Island with pause and resume, and the scan keeps going after the user leaves the app. While a library scan runs, its progress (items checked of total, percent) is visible in the iPhone's Dynamic Island and on the Lock Screen, even when the user switches to another app. From there the user can pause, resume, or stop the scan. The scan continues running in the background for as long as iOS allows, and if iOS suspends the app the scan pauses safely and resumes without starting over. iclean only ever suggests what to remove: no photo or video is ever deleted automatically, in the background, or from the Dynamic Island; removal happens only when the user reviews results in the app and confirms."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md). Requirements from that
spec are cited as "001 FR-nnn". This feature changes one of its decisions: a scan the
user started may now keep running after they leave the app (see FR-012 below).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Watch the scan from anywhere on the phone (Priority: P1)

A full scan of a big library takes minutes. Today the user has to keep iclean open the
whole time. With this feature, they tap Scan, switch to Messages or lock the phone, and
the scan keeps going. Its progress is visible without opening iclean: on iPhones with a
Dynamic Island it appears there, and on every iPhone it appears on the Lock Screen,
showing iclean's icon, a progress bar, and "1,240 of 10,000 checked". When the scan
finishes, the progress display goes away and the results are waiting the next time the
user opens iclean.

**Why this priority**: This is the whole point of the request. Without it, a long scan
blocks the phone, and users give up before it finishes.

**Independent Test**: Start a scan on a library large enough to take over a minute,
leave the app, and confirm that progress appears outside the app within seconds and
keeps advancing. Return after the scan would have finished and confirm the results are
shown without rescanning.

**Acceptance Scenarios**:

1. **Given** a scan is running, **When** the user switches to another app or locks the
   phone, **Then** within 5 seconds the scan's progress (icon, progress bar, items
   checked of total) is shown outside the app and keeps advancing.
2. **Given** a scan is running outside the app, **When** it finishes, **Then** the
   progress display disappears and opening iclean shows the results immediately.
3. **Given** a scan is running outside the app, **When** the user opens iclean,
   **Then** the in-app Scanning screen shows the same progress and the controls from
   001 (Pause, Stop).

---

### User Story 2 - Stop the scan from outside the app, resume later (Priority: P2)

While the scan runs outside the app, the user decides it is a bad time (battery, heat,
they need the phone fast). The progress display has a Stop control. Stopping is safe:
everything checked so far is kept. The next time they open iclean, the Scanning screen
says the scan was stopped from outside the app and offers Resume, which continues from
where it left off.

**Why this priority**: Users need a way out of a background job. Making "stop" lossless
removes the fear of using it.

**Independent Test**: Start a scan, leave the app, stop the scan from the progress
display, reopen iclean, resume, and confirm the scan finishes without re-checking the
items that were already done.

**Acceptance Scenarios**:

1. **Given** a scan is running outside the app, **When** the user activates Stop on the
   progress display, **Then** the display goes away within 5 seconds and no progress is
   lost.
2. **Given** a scan was stopped from outside the app, **When** the user opens iclean,
   **Then** the Scanning screen shows it as paused, says it was stopped from outside the
   app, and offers Resume.
3. **Given** a scan was stopped from outside the app and 3,000 of 10,000 items were
   checked, **When** the user taps Resume, **Then** only the remaining 7,000 items are
   checked.
4. **Given** the user paused the scan inside the app, **When** they leave the app,
   **Then** no work happens and no progress display is shown outside the app; resuming
   inside the app shows it again.

---

### User Story 3 - The phone can end the scan at any time, nothing is lost (Priority: P3)

iOS decides how long an app may work after the user leaves it. It may end the scan to
save battery, because the phone is hot, because the user turned off background activity
for iclean, or because the phone is an older model or system version that offers no
background allowance at all. Whatever the reason, the scan pauses safely and resumes
without starting over.

**Why this priority**: This is what makes Story 1 trustworthy. A background scan that
could lose work or drain the battery would be worse than none.

**Independent Test**: Start a scan, leave the app, and remove the background allowance
(for example by turning off Background App Refresh for iclean, or by running on a system
version without background continuation). Confirm the scan pauses, that returning to
the app continues it, and that no item is checked twice.

**Acceptance Scenarios**:

1. **Given** a scan is running outside the app, **When** the system ends the
   background allowance, **Then** the scan pauses within 5 seconds, progress is saved,
   and the phone does no further scanning work.
2. **Given** the scan was paused because the system ended the allowance (not because
   the user stopped it), **When** the user returns to iclean, **Then** the scan resumes
   by itself from where it left off.
3. **Given** the phone offers no background allowance at all, **When** the user leaves
   the app during a scan, **Then** the scan pauses shortly after and resumes by itself
   when the user returns.
4. **Given** iclean was closed from the app switcher during a background scan,
   **When** the user opens iclean again, **Then** Home offers Resume Scan and it
   continues from the last saved point (as in 001).

---

### User Story 4 - iclean only ever suggests (Priority: P4)

No matter where a scan runs, iclean never removes anything on its own. A scan only
produces suggestions. Nothing is removed when a scan finishes, when the app opens, on a
schedule, or from the progress display outside the app. Removal happens only after the
user reviews the results inside the app and confirms, exactly as in 001.

**Why this priority**: Background work makes users nervous about what an app does
unattended. This story states the guarantee so it can be tested, not just assumed.

**Independent Test**: Run several full scans to completion while the app is in the
background, then confirm the photo library has exactly as many items as before.

**Acceptance Scenarios**:

1. **Given** a scan completes while the app is in the background, **When** the user
   opens iclean, **Then** the library is unchanged and the results are suggestions
   with the usual review and confirm flow.
2. **Given** the progress display outside the app, **When** the user looks at its
   controls, **Then** the only action is Stop; there is no remove, clean, or confirm.

---

### Edge Cases

- **Nothing to scan**: a scan that finishes within seconds may never show progress
  outside the app. That is fine; the display is only for scans still running when the
  user leaves.
- **Phone gets hot**: the thermal pause from 001 applies in the background too. While
  paused for heat the progress display stays, and the scan continues when the phone
  cools, unless the system ends the allowance first (Story 3).
- **Low Power Mode or Background App Refresh off**: the scan runs while the app is open
  and pauses shortly after the user leaves; it resumes by itself on return. The
  Scanning screen says so before the user leaves (FR-013).
- **Progress display and in-app screen disagree**: both show the same saved progress;
  the in-app screen updates at least as often as the outside display.
- **User stops outside the app, then opens iclean**: shown as paused with the reason
  and Resume (Story 2). The scan is not resumed automatically, because the user asked
  for it to stop.
- **System ends the allowance and the user cannot tell why**: if the app cannot tell a
  user Stop from a system stop, it treats it as a user Stop (stay paused, offer Resume)
  rather than restart work the user may have wanted stopped.
- **Scan finishes while the phone is locked**: the display disappears; no notification
  is sent (see Assumptions).
- **Quick check on app open (001 FR-005a)**: unchanged; it never runs outside the app.
- **Two scans at once**: still impossible; starting a scan while one is paused resumes
  it (001).
- **Photos access removed while scanning in the background**: the scan pauses as if the
  system ended it; on return the Access screen from 001 explains what to do.

## Requirements *(mandatory)*

### Functional Requirements

**Progress outside the app**

- **FR-001**: While a user-started full scan is running and iclean is not in the
  foreground, the system MUST show the scan's progress outside the app: iclean's name or
  icon, a progress indicator, and the count of items checked out of the total. On
  iPhones with a Dynamic Island it appears there; on every iPhone it appears on the Lock
  Screen.
- **FR-002**: Progress shown outside the app MUST update at least every 100 items
  checked and MUST never show a value behind what the app has saved.
- **FR-003**: The progress display MUST offer exactly one action, Stop. It MUST NOT
  offer any action that removes, changes, or downloads photos or videos.
- **FR-004**: When the scan finishes, is stopped, or is paused inside the app, the
  progress display MUST disappear within 5 seconds.

**Keeping the scan going**

- **FR-005**: A user-started full scan MUST keep running after the user leaves the app
  for as long as the system allows, with the same work, same order, and same saving of
  progress as in the foreground (001 FR-005, FR-006).
- **FR-006**: Stopping the scan from outside the app MUST be lossless: it MUST behave as
  a pause, keeping every result and the resume point.
- **FR-007**: When the system ends the background allowance for any reason, the scan
  MUST pause safely within 5 seconds, save its progress, and do no further work until
  the app is in the foreground again.
- **FR-008**: After a scan was stopped from outside the app or ended by the system, the
  in-app Scanning screen MUST show it as paused, say that it was stopped outside the app,
  and offer Resume. Resume MUST continue from the saved point and MUST NOT re-check items
  already checked.
- **FR-009**: When the app can tell that the scan paused only because it had no
  background allowance (the user did not stop it), the scan MUST resume by itself when
  the app returns to the foreground. When the app cannot tell a user Stop from a system
  stop, it MUST stay paused and offer Resume (FR-008).
- **FR-010**: On phones or system versions that offer no background continuation, the
  scan MUST run while the app is open, pause shortly after the user leaves, and resume
  by itself when the user returns (FR-009). Progress outside the app is not shown on
  such phones.
- **FR-011**: A scan paused inside the app MUST do no work and MUST show no progress
  outside the app. Resuming inside the app restores both.
- **FR-012**: This feature replaces one sentence of 001 FR-005a. New wording: "A full
  scan runs only when the user starts it. Each time the app is opened, it quickly checks
  for photos added or changed since the last scan. A scan is never started or scheduled
  while the app is in the background, but a scan the user started may continue after
  they leave the app, for as long as the system allows."
- **FR-013**: Before the user leaves the app, the Scanning screen MUST say whether the
  scan will keep going outside the app (and where progress will show) or will pause when
  they leave.

**Suggestion only**

- **FR-014**: Background scanning MUST NOT remove, change, or download any photo or
  video, and MUST follow every privacy rule of 001: on-device only, previews only, no
  network (001 FR-001, FR-014, FR-017).
- **FR-015**: Nothing MUST ever be removed automatically: not when a scan finishes, not
  when the app opens, not on a schedule, and not from outside the app. Removal happens
  only through the in-app confirmation sheet followed by the system's own confirmation
  (001 FR-012, FR-013).
- **FR-016**: The in-app Scanning screen's new states (stopped outside the app, paused
  because the allowance ended, will pause when you leave) MUST be readable by VoiceOver
  and use Dynamic Type (001 FR-017a).

### Key Entities

- **Scan Session** (from 001): extended with *why it paused*: the user paused it inside
  the app, the user stopped it from outside the app, or the system ended the background
  allowance. The reason decides whether the scan resumes by itself (FR-009).
- **Background Allowance**: whether the system currently lets the scan keep working
  after the user leaves the app. Decides what the Scanning screen says (FR-013) and
  whether progress shows outside the app (FR-001, FR-010).
- **Progress Display**: what the user sees outside the app: name or icon, progress,
  items checked of total, and the Stop action (FR-001 to FR-004).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On an iPhone with the current system version, progress appears outside
  the app within 5 seconds of leaving the app with a scan running, in 10 of 10 trials.
- **SC-002**: A first full scan of 10,000 photos that is started and then left in the
  background finishes without the user returning, in at least 9 of 10 trials on a
  charged phone that is not in Low Power Mode, within the 10-minute budget of 001
  SC-001.
- **SC-003**: Stopping from outside the app and resuming inside it re-checks 0 items
  that were already checked, measured by the number of items analyzed after Resume.
- **SC-004**: 100% of scans ended by the system leave a resumable state; no scan ever
  restarts from zero.
- **SC-005**: Zero photos or videos are removed by any background or automatic path:
  after 20 background scans of a test library, its item count is unchanged (reaffirms
  001 SC-005).
- **SC-006**: With networking blocked, a scan that runs in the background completes and
  monitoring shows zero network requests (001 SC-006).
- **SC-007**: In a usability check, 9 of 10 users can find and use Stop outside the app
  and Resume inside it without help.

## Assumptions

- The progress display outside the app is the phone's own system display for
  long-running app work. iclean fills in its text and progress and does not draw its
  own. That is why the only action outside the app is Stop: pause and resume stay inside
  the app, and Stop outside is treated as a lossless pause.
- Background continuation is available from the phone's current major system version
  on. On older versions the scan pauses shortly after the user leaves and resumes when
  they return (FR-010).
- iPhones with a Dynamic Island are the iPhone 14 Pro and later; all of them can run the
  current system version. Other iPhones show the same progress on the Lock Screen.
- How long the scan may keep running outside the app is decided by the phone, not by
  iclean. Low battery, heat, Low Power Mode, and Background App Refresh being off can
  shorten or prevent it.
- No notification is sent when a scan finishes outside the app; the user sees results
  on the next open. A completion notification may be considered later.
- The quick check on app open (001 FR-005a) is unchanged and always runs in the
  foreground.
- Everything from 001 about privacy, confirmation, and Recently Deleted still applies
  unchanged; this feature adds no new data and no network use (see the plan's Data &
  Network statement).
