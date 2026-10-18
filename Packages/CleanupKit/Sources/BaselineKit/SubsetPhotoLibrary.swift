import CleanupKit
import Foundation

/// Shows only some assets of another library. The baseline check scans through it, so it
/// never touches the rest of the person's own photos.
public struct SubsetPhotoLibrary: PhotoLibrary {
    private let base: any PhotoLibrary
    private let allowed: Set<String>

    public init(base: any PhotoLibrary, allowed: Set<String>) {
        self.base = base
        self.allowed = allowed
    }

    public func authorizationStatus() -> LibraryAccess { base.authorizationStatus() }
    public func requestAuthorization() async -> LibraryAccess { await base.requestAuthorization() }

    public func fetchAllItems() async -> [AssetMetadata] {
        await base.fetchAllItems().filter { allowed.contains($0.assetID) }
    }

    public func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
        await base.fetchItems(withIDs: assetIDs.filter(allowed.contains))
    }

    public func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
        allowed.contains(assetID) ? await base.preview(for: assetID, maxPixels: maxPixels) : .unavailable
    }

    public func localByteSize(for assetID: String) async -> Int64? {
        allowed.contains(assetID) ? await base.localByteSize(for: assetID) : nil
    }

    /// Removal is not part of the check.
    public func remove(_ assetIDs: [String]) async -> RemovalResult {
        RemovalResult(removed: [], failed: assetIDs)
    }

    public func changes() -> AsyncStream<LibraryChange> { base.changes() }
}
