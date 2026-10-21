# Contract: Services (delta to 001, 002 and 003)

## Scanner (additive)

`startFullScan`, `quickCheck`, `pause(reason:)`, `resume`, and `stop` keep their signatures.
`startFullScan()` now runs the plan's steps in order and returns the same `AsyncStream`.

```swift
public protocol Scanner: Sendable {
    // existing members unchanged
    func stopAfterCurrentStep() async
    func continueFindingMore() async -> AsyncStream<ScanProgress>   // only the missing work
    func runNow(_ step: StepKind) async                              // ends power and Low Power waits only
}

public extension ScanProgress {
    var plan: CleaningPlan? { get }          // per-step state, counts, waiting reason
    var throttle: ThrottleReason? { get }    // why the pace is reduced, if it is
    var blockCompleted: BlockEvent? { get }  // set when a block or step boundary was reached
}

public struct BlockEvent: Sendable { let step: StepKind; let block: Int; let checked: Int; let total: Int }
```

The app publishes a snapshot whenever `blockCompleted` is set.

## Run profile (pure)

```swift
public func runProfile(
    capabilities: DeviceCapabilities, conditions: Conditions, effort: ScanEffort
) -> RunProfile

public protocol CapabilityProbe: Sendable { func capabilities() -> DeviceCapabilities }

public protocol ConditionsProvider: Sendable {
    var conditions: AsyncStream<Conditions> { get }
    func current() -> Conditions
}

public actor ScanGovernor {   // owns hysteresis; reads a Clock so tests can run it instantly
    init(probe: CapabilityProbe, conditions: ConditionsProvider, effort: ScanEffort, clock: any Clock<Duration>)
    func allowance() -> RunProfile
}
```

`ScanPipeline.init` takes a `ScanGovernor` in place of the fixed `concurrency` and the
`thermalState` closure; the old parameters remain as a fixed-profile convenience for tests.

## Store (additions)

```swift
func transaction(...)                        // unchanged
func slimItems() async throws -> [SlimItem]  // metadata, scalars, dHash; no blobs
func blobs(for assetIDs: [String]) async throws -> [String: ItemBlobs]  // thumbprint, feature print
func items(withIDs: [String]) async throws -> [LibraryItem]            // for display rows
func snapshot() async throws -> ResultsSnapshot?
func saveSnapshot(_ s: ResultsSnapshot) async throws
func itemsRevision() async throws -> Int64
```

## ResultsBuilder (changes)

```swift
func buildResults(slim: [SlimItem], blobs: BlobSource, protected: Set<String>,
                  continuity: ContinuityMap) async -> CleanupResults
```

`BlobSource` fetches thumbprints and feature prints on demand. `ContinuityMap` carries the
seen groups, shown keepers, and explicit deselections from the previous snapshot.

## Detector bounds (changes)

- `SimilarShotsDetector`: each photo is compared with at most `maxNeighbours` (12) following
  photos inside the 60 s window.
- `DuplicatePhotoDetector`: at most `maxConfirmationsPerPhoto` and a total budget for thumbprint
  confirmations; near-constant fingerprints are skipped.

## Guarantees (each has a unit test)

- **G1** A worse condition never raises width or enables a step (`RunProfileTests`).
- **G2** The final snapshot equals a one-shot build over the same items, for random block orders
  and sizes (`PhasedScanTests.finalEqualsOneShot`).
- **G3** An update never undoes a selection, a keeper the user saw, a keep mark, or a removal
  (`ReviewIntentTests`).
- **G4** No category shows its empty state while a step that feeds it is unfinished
  (`PhasedScanTests.noEarlyClean`).
- **G5** A kill in any step repeats at most one piece (`DurableScanTests`, parameterized by step).
- **G6** Stop after a step, relaunch, continue: only missing work runs
  (`PhasedScanTests.stopAndContinue`).
- **G7** Quick wins run with no photo analysis and list screenshots as final
  (`PhasedScanTests.quickWinsAreFinal`).
- **G8** Build time and memory stay bounded for 3,000 same-minute photos, 15% clustered
  fingerprints, and 100,000 items (`ScaleGuardTests`, Release only).
- **G9** Launch reads the snapshot and does not call `slimItems()` when the revision matches
  (`PhasedScanTests.launchUsesSnapshot`).
- **G10** The preview size passed to `PhotoLibrary.preview` is the same for every profile
  (`RunProfileTests.previewSizeIsFixed`).
