# Contract: CleanupKit service interfaces

The app target talks to the `CleanupKit` package only through these protocols. Every
protocol has an in-memory fake for tests, so all logic runs without a real photo library.
Signatures are indicative; names and shapes are what tasks and tests rely on.

## PhotoLibrary — the only code that touches PhotoKit

```swift
public protocol PhotoLibrary: Sendable {
    func authorizationStatus() -> LibraryAccess            // .full / .limited / .denied / .notDetermined
    func requestAuthorization() async -> LibraryAccess
    func fetchAllItems() async -> [AssetMetadata]          // metadata only, no pixels
    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult
    func localByteSize(for assetID: String) async -> Int64? // nil when not stored locally
    func remove(_ assetIDs: [String]) async -> RemovalResult
    func changes() -> AsyncStream<LibraryChange>           // live library changes
}

public enum PreviewResult: Sendable {
    case local(CGImage)           // full-quality item is on the phone
    case cloudPreview(CGImage)    // only a low-res preview is on the phone
    case unavailable              // counted as "not scanned"
}
```

**Guarantees**
- Never requests network access. The real implementation always sets
  `isNetworkAccessAllowed = false` (research R2); a unit test asserts this on every
  request-options object it builds.
- `remove` only moves items to Recently Deleted and reports per-item success.
- In the free app a video is not analyzed: no preview is requested for it. Its metadata is
  still stored, marked `analysisSource == .metadataOnly` with a nil `Analysis`, so Large
  Videos can rank it by size. `.metadataOnly` is not a failure: it is not counted in
  `notScanned` and is not retried (amended 2026-10-18, see
  specs/004-phased-cleaning/spec.md FR-004a).
- With Pro (`ProFeatures.videoAnalysis`, off by default in every release build) a video is
  analyzed from its poster frame, and the next full scan analyzes videos the free app
  stored as `.metadataOnly`; a quick check never starts that work.

## Analyzer — pure functions over a preview

```swift
public protocol Analyzer: Sendable {
    func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis
}

public struct Analysis: Sendable {
    public let dHash: UInt64
    public let featurePrint: Data
    public let sharpness: Double
    public let aestheticsScore: Double?
    public let faceQuality: Double?
}
```

## Scanner

```swift
public protocol Scanner: Sendable {
    func startFullScan() -> AsyncStream<ScanProgress>
    func quickCheck() async -> ScanProgress     // new/changed items only (FR-005a)
    func pause() async
    func resume() -> AsyncStream<ScanProgress>
    func stop() async
}

public struct ScanProgress: Sendable {
    public let processed: Int
    public let total: Int
    public let notScanned: Int
    public let state: ScanState                 // see data-model.md
}
```

## ResultsBuilder — groups, categories, default selection

```swift
public protocol ResultsBuilder: Sendable {
    func buildResults(items: [LibraryItem], keepMarks: Set<String>) -> CleanupResults
}

public struct CleanupResults: Sendable {
    public let categories: [CategoryResult]     // order: Duplicates, Similar, Blurry,
                                                // Screenshots, Large Videos
                                                // (Pro adds Duplicate Videos between
                                                // Screenshots and Large Videos)
    public let defaultSelection: Set<String>    // FR-010a
    public let notScannedCount: Int
}
```

**Guarantees** (each has a unit test)
- An item appears in at most one category (category order rule).
- Favorites, keep-marked items and shared-album items are never in `defaultSelection`
  and never flagged.
- Every group has ≥ 1 keeper; keepers are never in `defaultSelection`.
- Large Videos items are never in `defaultSelection`.
- Duplicate Videos is Pro only since 2026-10-18: the free app does not analyze videos, so
  the free app has no such category (see specs/004-phased-cleaning/spec.md FR-004a).
- Edited items are never grouped with unedited items.

## Remover

```swift
public protocol Remover: Sendable {
    func summary(for selection: Set<String>, in results: CleanupResults) -> RemovalPreview
    func remove(_ selection: Set<String>, in results: CleanupResults) async -> CleanupSummary
}
```

**Guarantees**
- `remove` refuses (returns an error) if a group would lose all members without the
  explicit "remove all" confirmation flag (FR-016).
- `CleanupSummary.bytesFreed` counts only items that were actually removed.

## Store

```swift
public protocol Store: Sendable {
    func items() async throws -> [LibraryItem]
    func upsert(_ items: [LibraryItem]) async throws
    func keepMarks() async throws -> Set<String>
    func setKeep(_ assetID: String, _ keep: Bool) async throws
    func clearKeepMarks() async throws
    func saveSession(_ session: ScanSession) async throws
    func currentSession() async throws -> ScanSession?
    func deleteAllData() async throws           // FR-018
}
```
