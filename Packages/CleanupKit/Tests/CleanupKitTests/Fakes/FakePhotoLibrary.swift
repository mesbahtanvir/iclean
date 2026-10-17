import CoreGraphics
import Foundation

@testable import CleanupKit

/// In-memory photo library for tests.
final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {
    struct Asset {
        var metadata: AssetMetadata
        var preview: PreviewResult
        var size: Int64?
    }

    private let lock = NSLock()
    private var assets: [String: Asset] = [:]
    private var order: [String] = []
    var access: LibraryAccess = .full
    var failingRemovals: Set<String> = []
    var cancelRemoval = false
    var previewDelay: Duration = .zero
    private(set) var previewRequests: [String] = []
    private var listeners: [AsyncStream<LibraryChange>.Continuation] = []

    func add(_ metadata: AssetMetadata, preview: PreviewResult, size: Int64? = 1_000) {
        lock.withLock {
            if assets[metadata.assetID] == nil { order.append(metadata.assetID) }
            assets[metadata.assetID] = Asset(metadata: metadata, preview: preview, size: size)
        }
    }

    func update(_ assetID: String, _ change: (inout AssetMetadata) -> Void) {
        lock.withLock { change(&assets[assetID]!.metadata) }
    }

    func delete(_ assetID: String) {
        lock.withLock {
            assets.removeValue(forKey: assetID)
            order.removeAll { $0 == assetID }
        }
        emit(LibraryChange(removed: [assetID]))
    }

    func emit(_ change: LibraryChange) {
        lock.withLock { listeners }.forEach { $0.yield(change) }
    }

    var allIDs: [String] { lock.withLock { order } }

    func authorizationStatus() -> LibraryAccess { access }
    func requestAuthorization() async -> LibraryAccess { access }

    func fetchAllItems() async -> [AssetMetadata] {
        lock.withLock { order.compactMap { assets[$0]?.metadata } }
    }

    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
        if previewDelay > .zero { try? await Task.sleep(for: previewDelay) }
        return lock.withLock {
            previewRequests.append(assetID)
            return assets[assetID]?.preview ?? .unavailable
        }
    }

    func localByteSize(for assetID: String) async -> Int64? {
        lock.withLock { assets[assetID]?.size }
    }

    func remove(_ assetIDs: [String]) async -> RemovalResult {
        if cancelRemoval { return RemovalResult(removed: [], failed: [], cancelled: true) }
        let (removed, failed): ([String], [String]) = lock.withLock {
            var removed: [String] = []
            var failed: [String] = []
            for id in assetIDs {
                if failingRemovals.contains(id) || assets[id] == nil {
                    failed.append(id)
                } else {
                    assets.removeValue(forKey: id)
                    order.removeAll { $0 == id }
                    removed.append(id)
                }
            }
            return (removed, failed)
        }
        return RemovalResult(removed: removed, failed: failed)
    }

    func changes() -> AsyncStream<LibraryChange> {
        let (stream, continuation) = AsyncStream<LibraryChange>.makeStream()
        lock.withLock { listeners.append(continuation) }
        return stream
    }
}

/// A fixed-result analyzer so pipeline tests do not depend on Vision.
struct StubAnalyzer: Analyzer {
    func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
        Analysis(dHash: UInt64(image.width), featurePrint: Data(), sharpness: 100)
    }
}

/// Test helpers to build items quickly.
enum Make {
    static func meta(
        _ id: String, kind: ItemKind = .photo, date: Date = Date(timeIntervalSince1970: 0),
        width: Int = 4032, height: Int = 3024, favorite: Bool = false, edited: Bool = false,
        duration: Double? = nil, portrait: Bool = false, longExposure: Bool = false,
        burst: String? = nil, albums: [String] = [], modified: Date? = nil
    ) -> AssetMetadata {
        AssetMetadata(
            assetID: id, kind: kind, captureDate: date,
            modificationDate: modified ?? date, pixelWidth: width, pixelHeight: height,
            duration: duration, isFavorite: favorite, hasAdjustments: edited,
            isPortrait: portrait, isLongExposure: longExposure, burstID: burst,
            albumNames: albums)
    }

    static func item(
        _ m: AssetMetadata, source: AnalysisSource = .localPreview, dHash: UInt64 = 0,
        thumbprint: Data = Data(), print: Data = Data(), sharpness: Double = 0.8, aesthetics: Double? = nil,
        face: Double? = nil, size: Int64? = 1_000
    ) -> LibraryItem {
        LibraryItem(
            metadata: m, analysisSource: source,
            analysis: Analysis(
                dHash: dHash, thumbprint: thumbprint, featurePrint: print, sharpness: sharpness,
                aestheticsScore: aesthetics, faceQuality: face),
            byteSize: size)
    }
}
