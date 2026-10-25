# Feature Specification: iclean on Every Apple Platform with iCloud Photos

**Feature Branch**: `005-all-apple-platforms`

**Created**: 2026-10-18

**Status**: Draft

**Input**: User description: "Now this app should be available on all the Apple platforms
where iCloud Photo Library is available and have processing power to be able to do that, and
work appropriately based on the device."

**Builds on**: [001-photo-cleanup](../001-photo-cleanup/spec.md) through
[004-phased-cleaning](../004-phased-cleaning/spec.md). Today iclean is an iPhone app. This
feature brings it to iPad and Mac, runs it on Apple Vision Pro, and says clearly why it does
not go to Apple TV or Apple Watch. The pace, steps, and results rules of 004 apply on every
platform; this spec covers what differs by device.

## Where it will and will not run

| Platform | Decision | Why |
|---|---|---|
| iPhone | Supported (today) | |
| iPad | Native app | Same Photos access and background rules as iPhone; needs layout, orientation, and pointer and keyboard work |
| Mac (Apple silicon, macOS 15 or later) | Native app | Same Photos access; no background tasks exist, so interruptions work differently |
| Apple Vision Pro | Runs the iPad app in a window | The code builds for it, but a native layout and gaze targets are a separate piece of work; background continuation does not exist there |
| Mac with an Intel processor | Not supported | No Neural Engine; analysis is far slower and the time limits assume Apple silicon |
| Apple TV | Not supported | The library is a cloud view with no local originals, there is no durable app storage, and no sensible way to review and remove on a remote |
| Apple Watch | Not supported | The system gives apps no access to the photo library |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - iPad: the same cleanup, on a bigger screen (Priority: P1)

A user opens iclean on an iPad with their iCloud library. The categories sit in a sidebar, the
selected category fills the screen, and a group opens beside it instead of replacing it. The
app works in every orientation, in Split View and Stage Manager, with a trackpad or keyboard.
Everything from 001 to 004 works as on iPhone, and nothing says "iPhone" on an iPad.

**Why this priority**: It needs the least new code (the app and its background behaviour
already run on iPadOS) and covers a large audience with the biggest screens for comparing
photos.

**Independent Test**: Run the existing UI suite on an iPad simulator in portrait and landscape,
plus layout tests at Split View widths. Assert every flow passes, every control is reachable,
and no string names the wrong device.

**Acceptance Scenarios**:

1. **Given** an iPad in landscape, **When** the user opens Duplicates, **Then** the category
   list stays visible and the group opens in a detail area beside it.
2. **Given** the iPad is rotated or the window resized to a third of the screen, **When** the
   app is open, **Then** the layout adapts and the Scan button and a category row stay
   reachable.
3. **Given** a scan is running and the user leaves the app, **When** they return, **Then** the
   behaviour is that of 002 and 003 (continuation on iPadOS 26 or later, the grace period and
   resume otherwise), and the wording does not mention the Dynamic Island.
4. **Given** a pointer or keyboard is attached, **When** the user reviews a group, **Then** the
   keyboard behaviour in User Story 2 works the same way.

---

### User Story 2 - Mac: a native app that treats the Mac like a Mac (Priority: P2)

A user opens iclean on a Mac with Apple silicon. They see a sidebar of categories, a toolbar
with Scan, Pause and Stop, and menu commands with shortcuts. They review with the keyboard:
arrow keys move, Space marks or unmarks, Return opens the photo. Delete opens the confirmation
and never removes anything by itself. Progress shows on the Dock icon. Closing the window does
not end a running scan; quitting pauses it safely and the next launch resumes. Putting the Mac
to sleep pauses the scan and waking it resumes. Nothing ever touches the network, and the
system enforces that.

**Why this priority**: The Mac is where the largest libraries live and where there is the most
speed to gain, but it needs real platform work: another way to stay alive, different power and
sleep behaviour, and keyboard review.

**Independent Test**: Run the baseline library check on a Mac set up with a separate test
user's Photos library. Run the keyboard UI tests, a sleep and wake test with injected
notifications, a quit and relaunch test, and a check that the app's entitlements contain no
network permission.

**Acceptance Scenarios**:

1. **Given** the Mac app is open on a library, **When** the user taps Scan and hides the
   window, **Then** the scan keeps its normal speed and Dock shows its progress.
2. **Given** a scan is running, **When** the Mac goes to sleep and wakes, **Then** the scan
   paused at the sleep and resumes at the wake, and no item was counted as failed because of
   the sleep.
3. **Given** a scan is running, **When** the user quits the app, **Then** the scan pauses
   safely and the next launch offers Resume from the saved point (003).
4. **Given** the user is reviewing a group, **When** they press Space, an arrow, Return, or
   Delete, **Then** Space marks or unmarks the focused photo, arrows move focus, Return opens
   the photo, and Delete opens the confirmation sheet without removing anything.
5. **Given** Select All or a Shift-click range, **When** applied, **Then** no keeper is marked.
6. **Given** the user's Photos app uses a library other than the System Photo Library,
   **When** iclean starts, **Then** it explains that macOS shares only the system library with
   apps, and does not show an empty "clean" library.
7. **Given** a Mac on battery under 20%, **When** a scan runs, **Then** the 004 power rules
   apply and the status says "Waiting for your Mac to be plugged in".

---

### User Story 3 - Apple Vision Pro: the iPad app in a window (Priority: P3)

A Vision Pro user opens the iPad version in a window. Scanning runs while the window is open;
closing the window or taking off the headset pauses it, and returning resumes. The wording says
this plainly. Review and removal work with the usual confirmation.

**Why this priority**: It needs almost no new code, but it must be checked on a headset and
described honestly, because no background continuation exists there.

**Independent Test**: Run the iPad build on a visionOS simulator, and on a headset when one is
available. Assert launch, a scan, pause and resume on window close, and removal with
confirmation.

**Acceptance Scenarios**:

1. **Given** a scan is running in the window, **When** the user closes it or removes the
   headset, **Then** the scan pauses with everything saved, and resumes on return.
2. **Given** the iPad app runs in compatibility mode, **When** it tries to use a continued
   task, **Then** it falls back to the grace period and resume without an error.

---

### User Story 4 - The same promises everywhere, proved by the same test (Priority: P4)

On any supported device the promises of 001 hold: nothing leaves the device, nothing is
removed without confirmation, removal goes to Recently Deleted, and results are the same for
the same photos. The baseline photo library check, written once, runs on each platform and
produces a report that can be lined up against the others.

**Why this priority**: The platforms differ in details (preview decoding, Vision revisions,
what counts as a screenshot). Only one shared test can show a difference quickly.

**Independent Test**: Run `scripts/run-baseline.sh` on an iPhone, an iPad, a Mac, and a
visionOS simulator, then `scripts/compare-baseline-reports.py` over the reports.

**Acceptance Scenarios**:

1. **Given** the baseline library on each platform, **When** the check runs, **Then** every
   asserted check passes, skipped checks are named with their reason, and the borderline
   photos are reported per device.
2. **Given** two platforms differ on a check, **When** the reports are compared, **Then** the
   check is marked and the capabilities row (feature prints, screenshot tagging) points at
   the cause.

---

### Edge Cases

- One iCloud library on several devices: each device scans its own view and keeps its own
  results; identifiers are device-local, so results are not shared between devices (and doing
  so would need the network).
- Optimize Storage (iPhone, iPad) and Optimize Mac Storage: many originals are not on the
  device. The existing cloud-preview path applies, with lower confidence (001 FR-014).
- Limited or denied access on a platform that behaves differently: the app plans from what it
  can see and says "checked N of M" for that set; it never shows a false "clean".
- A Mac with several windows open, or an iPad in Stage Manager with two iclean windows: only
  one scan runs and only one removal confirmation can be open at a time.
- The Mac app is run against a developer's own Photos library by mistake: debug tools that
  change favorites must refuse to run there without an explicit flag.
- An iPad app opened on a Mac or a headset through compatibility: the native Mac app is
  built, and Designed-for-iPad on Mac is turned off so the wrong build is never offered.
- Mac wakes from sleep while Photos is still syncing: items that fail around the wake are
  retried by 003, not marked as failed for good.

## Requirements *(mandatory)*

### Functional Requirements

**Availability**

- **FR-001**: iclean MUST run natively on iPad (iPadOS 18 or later) with all orientations,
  Split View, and Stage Manager.
- **FR-002**: iclean MUST run natively on Mac with Apple silicon (macOS 15 or later).
- **FR-003**: iclean MUST run on Apple Vision Pro (visionOS 2 or later) as the iPad app in a
  window.
- **FR-004**: iclean MUST NOT be offered for Apple TV, Apple Watch, or Intel Macs.
- **FR-005**: One product listing SHOULD cover iPhone, iPad, Mac, and Vision Pro (one
  identifier, one purchase), if the distribution plan allows. (Amended 2026-10-24: there is no
  purchase; iclean is free, specs/016-free-photos-only/spec.md.)

**Library, privacy, and removal**

- **FR-006**: Each device MUST scan its own view of the iCloud Photos library and keep its own
  results. No results are shared between devices.
- **FR-007**: On Mac the app MUST say clearly when macOS offers it no library or only the
  system library, and MUST NOT present a library it cannot see as clean.
- **FR-008**: Removal MUST need an explicit confirmation and move photos to Recently Deleted on
  every platform. Where the platform's behaviour cannot be read from its documentation, it
  MUST be verified on that platform before release.
- **FR-009**: On Mac, the system itself MUST prevent the app from using the network: the app
  MUST NOT carry any network permission, and a check MUST fail the build if one is added.

**Interruptions**

- **FR-010**: On iPad, behaviour in the background MUST follow 002 and 003. Wording MUST NOT
  mention things the iPad lacks (the Dynamic Island).
- **FR-011**: On Mac, a running scan MUST NOT be slowed because its window is hidden, MUST
  pause when the Mac goes to sleep and resume when it wakes, MUST keep running after the last
  window closes, and MUST pause losslessly when the app is quit. Progress MUST show on the
  Dock icon.
- **FR-012**: On Vision Pro, a running scan MUST pause when the window closes or the headset is
  removed and resume on return, and the wording MUST say so.
- **FR-013**: No platform MUST promise to continue after the app is quit.

**Review**

- **FR-014**: On iPad, Mac, and Vision Pro the layout MUST use the available space: a sidebar of
  categories, a content area, and a detail area for a group.
- **FR-015**: With a pointer or keyboard (iPad and Mac), click MUST focus a photo, a click on
  its check mark MUST toggle removal, Shift-click MUST mark a range, Command-click MUST toggle,
  Command-A MUST mark all removable photos, Space MUST toggle the focused photo, arrows MUST
  move focus, Return MUST open the photo, and a context menu MUST replace the long press.
- **FR-016**: Delete and Command-Delete MUST only open the confirmation sheet. Return MUST NOT
  confirm a removal. Select All and range selection MUST NOT mark a keeper.
- **FR-017**: A photo viewer and a group comparison MUST be openable in their own window on
  iPad and Mac.
- **FR-018**: With several windows open, only one scan MUST run, a launch MUST happen once, and
  only one removal confirmation MUST be possible at a time.

**Pace and wording**

- **FR-019**: The pace, steps, and power rules of 004 MUST apply on every platform, with
  platform signals: charging and battery on iPhone, iPad, and Vision Pro; the power source and
  sleep on Mac; a desktop Mac counts as always on power; a head-worn device runs one step
  cooler.
- **FR-020**: Every string that names the device, the background behaviour, or the system's
  confirmation MUST be correct for the device (iPhone, iPad, Mac, Apple Vision Pro). The Photos
  permission text MUST not say "iPhone" on other devices.
- **FR-021**: All screens MUST work with VoiceOver, Dynamic Type or the platform's text size,
  and, on Mac, the keyboard alone (001 FR-017a).

**Quality**

- **FR-022**: The build for every supported platform MUST be compiled on every change, so
  platform breakage cannot ship unnoticed.
- **FR-023**: The baseline library check MUST run on every supported platform and produce a
  report that can be compared across devices.
- **FR-024**: Each platform MUST have its own app icon and store images.

### Key Entities

- **Platform Behaviour**: how one platform keeps a scan alive, what interrupts it, and how it
  reports power. Hidden behind one interface so the scan does not care which platform it is on.
- **Review Focus**: the photo the keyboard or pointer is on, separate from which photos are
  marked for removal.
- **Window**: one view of the app. Several can exist; the scan and removal are shared.

## Success Criteria *(mandatory)*

Times marked estimate are targets until measured on the device class named.

- **SC-001**: The full UI suite passes on an iPad simulator in portrait and landscape, and the
  layout tests pass at a third, a half, and the full screen width.
- **SC-002**: The baseline library check passes on iPhone, iPad, and Mac, with every skipped
  check named, and the reports compare without an unexplained difference.
- **SC-003**: The Mac app's entitlements contain no network permission, checked on every build,
  and the no-network UI flow passes on Mac.
- **SC-004**: In 100 random quits during a Mac scan, every run resumes after relaunch and at
  most one piece is repeated (003 SC-001 on Mac).
- **SC-005**: In 20 sleep and wake cycles during a Mac scan, the scan pauses and resumes every
  time with no item marked failed because of the sleep.
- **SC-006**: In 100% of keyboard tests, Delete and Return remove nothing without the
  confirmation sheet, and Select All and range selection mark no keeper.
- **SC-007**: A first scan of 30,000 photos on an Apple-silicon Mac finishes in under 10 minutes
  (estimate about 3 to 4 minutes on an M4-class Mac; not yet measured).
- **SC-008**: The accessibility audit passes on iPad and Mac, apart from elements the system
  sizes itself.
- **SC-009**: Every supported platform builds in CI on every change.

## Assumptions

- In the free app, videos are not analyzed (004 FR-004a); video analysis is a Pro feature. The
  only video work is the Large Videos list by file size; on Mac its sizes are exact only if
  the sandbox lets the app read the video file's size, which is checked, and are estimates
  otherwise.
- The package lowers its Mac floor from macOS 26 to macOS 15, the lowest version that has the
  Vision requests the app uses. No code needs macOS 26.
- A native Vision Pro layout, and a native Mac layout richer than a sidebar and keyboard
  review (for example drag selection), are later work.
- Mac Catalyst is not used: it lacks background tasks and live progress and gives a worse Mac
  app than a native one.
- Distribution (one listing, notarization, screenshots, store review of cleaner apps) is
  planned here but happens outside the code.
- Everything in 001 to 004 about privacy, confirmation, durability, and pace applies unchanged.

## Decisions for you

Each has a default the plan follows unless you say otherwise.

1. **Apple silicon only on Mac.** Default: yes. Intel Macs have no Neural Engine, so analysis
   would be much slower and the 20-second per-photo limit would be too tight.
2. **Vision Pro runs the iPad app for now; native later.** Default: yes.
3. **One product listing for all platforms** (one identifier). Default: yes.
4. **On Mac, a running scan continues after the last window is closed, and Quit pauses it.**
   Default: yes, with progress on the Dock icon.
5. **Lower the package's Mac floor to macOS 15.** Default: yes.
