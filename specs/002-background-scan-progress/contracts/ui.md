# Contract: Screens and states (delta to 001)

Only the **Scanning** screen changes. See [001 contracts/ui.md](../../001-photo-cleanup/contracts/ui.md)
for everything else.

## Scanning screen

| Element | Accessibility id | Text |
|---------|------------------|------|
| Status headline (existing) | `scan.status` | "Scanning your library…" / "Paused" / "Paused to let your iPhone cool down" / **new** "Stopped from outside iclean" / **new** "Paused while you were away" |
| Progress (existing) | `scan.progress` | value = fraction; accessibility value "N of M" |
| Pause / Resume / Stop (existing) | `scan.pause`, `scan.resume`, `scan.stop` | |
| **New** footnote | `scan.whenYouLeave` | allowance `continues`: "Keeps scanning while you use other apps. Progress shows in the Dynamic Island and on the Lock Screen." / `pausesOnLeave`: "Pauses when you leave iclean and continues when you come back." / `unknown`: hidden |

## States

| State | Headline | Buttons | Footnote |
|-------|----------|---------|----------|
| running, allowance continues | Scanning your library… | Pause, Stop | continues text |
| running, allowance pausesOnLeave | Scanning your library… | Pause, Stop | pausesOnLeave text |
| paused (user) | Paused | Resume, Stop | hidden |
| paused (stoppedOutsideApp) | Stopped from outside iclean | Resume, Stop | hidden |
| paused (backgroundLimit) | Paused while you were away | Resume, Stop | hidden (auto-resumes on foreground, so rarely seen) |
| thermal pause | Paused to let your iPhone cool down | Pause, Stop | as running |

## Outside the app (system-drawn, iOS 26+)

Title "Scanning your library", subtitle "N of M checked" (or the thermal text), a
progress bar, and the system's Stop control. The app cannot add other controls.

## Rules

- All new text uses Dynamic Type and is read by VoiceOver (FR-016).
- No new screen; no new gesture-only action.
