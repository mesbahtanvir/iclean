import CoreGraphics
import Foundation

/// The only boundary to the Photos library. Implementations never use the network.
public protocol PhotoLibrary: Sendable {
    func authorizationStatus() -> LibraryAccess
    func requestAuthorization() async -> LibraryAccess
    /// Metadata for every item in the user's own library. No pixels.
    func fetchAllItems() async -> [AssetMetadata]
    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult
    /// Size of the item's files on the phone, or nil when not stored locally.
    func localByteSize(for assetID: String) async -> Int64?
    /// Moves items to Recently Deleted. iOS shows its own confirmation first.
    func remove(_ assetIDs: [String]) async -> RemovalResult
    /// Changes made to the library while the app is running.
    func changes() -> AsyncStream<LibraryChange>
}

public enum PreviewResult: @unchecked Sendable {
    /// The full-quality item is on the phone.
    case local(CGImage)
    /// Only a low-resolution preview is on the phone.
    case cloudPreview(CGImage)
    /// Nothing usable on the phone; counted as "not scanned".
    case unavailable

    public var image: CGImage? {
        switch self {
        case .local(let image), .cloudPreview(let image): image
        case .unavailable: nil
        }
    }

    public var source: AnalysisSource {
        switch self {
        case .local: .localPreview
        case .cloudPreview: .cloudPreview
        case .unavailable: .notScanned
        }
    }
}

public struct RemovalResult: Sendable, Equatable {
    public var removed: [String]
    public var failed: [String]
    /// The user cancelled the iOS confirmation; nothing was removed.
    public var cancelled: Bool

    public init(removed: [String], failed: [String], cancelled: Bool = false) {
        self.removed = removed
        self.failed = failed
        self.cancelled = cancelled
    }
}

public struct LibraryChange: Sendable, Equatable {
    public var insertedOrChanged: Set<String>
    public var removed: Set<String>

    public init(insertedOrChanged: Set<String> = [], removed: Set<String> = []) {
        self.insertedOrChanged = insertedOrChanged
        self.removed = removed
    }
}
