# Contract: Services (delta to 001)

Changes to `CleanupKit` public API. Everything not listed is unchanged from
[001 contracts/services.md](../../001-photo-cleanup/contracts/services.md).

## Scanner

```swift
public enum ScanPauseReason: String, Sendable, Codable {
    case user, stoppedOutsideApp, backgroundLimit
}

public struct ScanProgress: Sendable, Hashable {
    // existing fields …
    public var pauseReason: ScanPauseReason?      // non-nil only while state == .paused
    public var resumesOnForeground: Bool          // pauseReason == .backgroundLimit
}

public protocol Scanner: Sendable {
    func startFullScan() async -> AsyncStream<ScanProgress>
    func quickCheck() async -> ScanProgress
    func pause(reason: ScanPauseReason) async     // was pause()
    func resume() async
    func stop() async
}
```

`ScanPipeline.init` gains `progressEvery: Int = 10` (progress events) next to
`saveEvery: Int = 100` (store writes).

## Guarantees (each has a unit test)

- **G1 Pause is lossless**: after `pause(reason:)` returns, every item processed so far is
  in the store and the session is saved as `paused`; a later `startFullScan()` in a new
  process analyzes only what is left.
- **G2 Reason is reported**: the next `ScanProgress` after `pause(reason:)` has
  `state == .paused` and `pauseReason == reason`; after `resume()` it is nil.
- **G3 Auto-resume rule**: `resumesOnForeground` is true only for `.backgroundLimit`.
- **G4 Cadence**: with `progressEvery = n`, a progress event is emitted at least every
  `n` processed items.
- **G5 No removal path**: nothing in the scanning or continuation code can call
  `PhotoLibrary.remove`. (Enforced by review and by the UI test that counts library items
  after a background scan.)

## App-side continuation (app target, not in CleanupKit)

`ScanContinuation` (`@MainActor`) is the only type that touches BackgroundTasks and UIKit
background time:

- `scanStarted(scanner:)` — iOS 26+: register + submit a continued processing task;
  publishes `allowance` (`unknown` → `continues` or `pausesOnLeave`).
- `update(_ progress: ScanProgress)` — forwards processed/total to the task's `progress`
  and `updateTitle(_:subtitle:)`.
- `scanPausedByUser()` / `scanEnded()` — completes the task, ends background time.
- `appDidEnterBackground()` / `appWillEnterForeground()` — grace-period fallback.
- Expiration handlers call `scanner.pause(reason:)` with `.stoppedOutsideApp` (task) or
  `.backgroundLimit` (grace period).
