# Data Model: Scan Progress Outside the App

Delta to [001 data-model.md](../001-photo-cleanup/data-model.md). Nothing new is stored on
disk; the additions below are in-memory values reported to the UI.

## ScanProgress (in memory, unchanged fields plus)

| Field | Type | Notes |
|-------|------|-------|
| `pauseReason` | enum `user` / `stoppedOutsideApp` / `backgroundLimit`, optional | Set while `state == .paused`; nil otherwise |

Derived: `resumesOnForeground` is true only for `backgroundLimit` (spec FR-009).

## ScanPauseReason

| Value | Meaning | Set by | On return to foreground |
|-------|---------|--------|-------------------------|
| `user` | Pause tapped in the app | `AppModel.pauseScan()` | stays paused |
| `stoppedOutsideApp` | Continued processing task expired (user Stop or system) | task expiration handler | stays paused, Resume offered |
| `backgroundLimit` | Grace period ended with no continued processing task | background-time expiration handler | resumes automatically |

## Background allowance (in memory, app target)

| State | Meaning | Scanning screen says |
|-------|---------|----------------------|
| `unknown` | Scan starting, submission pending | nothing yet |
| `continues` | A continued processing task is queued or running | "Keeps scanning while you use other apps. Progress shows in the Dynamic Island and on the Lock Screen." |
| `pausesOnLeave` | Task refused, or iOS older than 26 | "Pauses when you leave iclean and continues when you come back." |

## ScanSession (stored, unchanged)

State transitions from 001 still hold. New edges only change *who* triggers them:

```text
running ──pause(user)──────────────▶ paused ──resume (user tap)──────────▶ running
running ──pause(stoppedOutsideApp)─▶ paused ──resume (user tap)──────────▶ running
running ──pause(backgroundLimit)───▶ paused ──resume (foreground / task)─▶ running
```

Invariant added: a paused session has every processed item written to the store
(flush-on-pause), so `processedItems` never exceeds the stored item count by more than
the in-flight concurrency.
