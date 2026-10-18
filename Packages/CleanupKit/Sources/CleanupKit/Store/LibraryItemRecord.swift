import Foundation
import SwiftData

/// Stored analysis of one Photos asset. Only identifiers and analysis results are
/// kept; the photos themselves stay in the Photos library.
@Model
final class LibraryItemRecord {
    @Attribute(.unique) var assetID: String
    var kindRaw: String
    var captureDate: Date?
    var modificationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double?
    var isFavorite: Bool
    var hasAdjustments: Bool
    var isPortrait: Bool
    var isLongExposure: Bool
    var burstID: String?
    var albumNames: [String]
    var analysisSourceRaw: String
    /// UInt64 dHash stored by bit pattern.
    var dHashBits: Int64?
    var thumbprint: Data?
    var featurePrint: Data?
    var sharpness: Double?
    var aestheticsScore: Double?
    var faceQuality: Double?
    var byteSize: Int64?
    var isSizeEstimated: Bool
    var analyzedAt: Date
    // 003: optional so stores written by earlier versions open unchanged.
    var scanFailureRaw: String?
    var scanAttempts: Int?
    // Date-aware keepers: optional so stores written by earlier versions open unchanged. They
    // fill in the next time the item's metadata is refreshed.
    var addedDate: Date?
    var hasLocation: Bool?

    init(_ item: LibraryItem) {
        assetID = item.assetID
        kindRaw = item.metadata.kind.rawValue
        captureDate = nil
        modificationDate = nil
        pixelWidth = 0
        pixelHeight = 0
        isFavorite = false
        hasAdjustments = false
        isPortrait = false
        isLongExposure = false
        albumNames = []
        analysisSourceRaw = item.analysisSource.rawValue
        isSizeEstimated = false
        analyzedAt = item.analyzedAt
        update(from: item)
    }

    func update(from item: LibraryItem) {
        let m = item.metadata
        kindRaw = m.kind.rawValue
        captureDate = m.captureDate
        modificationDate = m.modificationDate
        pixelWidth = m.pixelWidth
        pixelHeight = m.pixelHeight
        duration = m.duration
        isFavorite = m.isFavorite
        hasAdjustments = m.hasAdjustments
        isPortrait = m.isPortrait
        isLongExposure = m.isLongExposure
        burstID = m.burstID
        albumNames = m.albumNames
        addedDate = m.addedDate
        hasLocation = m.hasLocation
        analysisSourceRaw = item.analysisSource.rawValue
        // dHash, featurePrint and sharpness are nil unless the item was analyzed.
        let a = item.analysisSource.hasAnalysis ? item.analysis : nil
        dHashBits = a.map { Int64(bitPattern: $0.dHash) }
        thumbprint = a?.thumbprint
        featurePrint = a?.featurePrint
        sharpness = a?.sharpness
        aestheticsScore = a?.aestheticsScore
        faceQuality = a?.faceQuality
        byteSize = item.byteSize
        isSizeEstimated = item.isSizeEstimated
        analyzedAt = item.analyzedAt
        scanFailureRaw = item.scanFailure?.rawValue
        scanAttempts = item.scanAttempts
    }

    var item: LibraryItem {
        let metadata = AssetMetadata(
            assetID: assetID, kind: ItemKind(rawValue: kindRaw) ?? .photo,
            captureDate: captureDate, modificationDate: modificationDate,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, duration: duration,
            isFavorite: isFavorite, hasAdjustments: hasAdjustments, isPortrait: isPortrait,
            isLongExposure: isLongExposure, burstID: burstID, albumNames: albumNames,
            addedDate: addedDate, hasLocation: hasLocation)
        var analysis: Analysis?
        if let dHashBits, let featurePrint, let sharpness {
            analysis = Analysis(
                dHash: UInt64(bitPattern: dHashBits), thumbprint: thumbprint ?? Data(),
                featurePrint: featurePrint,
                sharpness: sharpness, aestheticsScore: aestheticsScore,
                faceQuality: faceQuality)
        }
        return LibraryItem(
            metadata: metadata,
            analysisSource: AnalysisSource(rawValue: analysisSourceRaw) ?? .notScanned,
            analysis: analysis, byteSize: byteSize, isSizeEstimated: isSizeEstimated,
            analyzedAt: analyzedAt,
            scanFailure: scanFailureRaw.flatMap(ScanFailure.init(rawValue:)),
            scanAttempts: scanAttempts ?? 0)
    }
}
