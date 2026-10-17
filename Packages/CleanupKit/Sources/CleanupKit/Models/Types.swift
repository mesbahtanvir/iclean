import Foundation

/// What kind of library item this is.
public enum ItemKind: String, Sendable, Codable, CaseIterable {
    case photo, screenshot, video, livePhoto

    public var isVideo: Bool { self == .video }
    public var isStillImage: Bool { self != .video }
}

/// Where an item's analysis came from (spec FR-014).
public enum AnalysisSource: String, Sendable, Codable {
    /// The full-quality item is on the phone.
    case localPreview
    /// Only a low-resolution preview is on the phone; the original is in iCloud.
    case cloudPreview
    /// No usable preview on the phone; the item was not analyzed.
    case notScanned
}

public enum LibraryAccess: String, Sendable {
    case full, limited, denied, notDetermined
}

public enum ScanState: String, Sendable, Codable {
    case idle, running, paused, stopped, completed
}

public enum ScanKind: String, Sendable, Codable {
    case full, quickCheck
}

/// Cleanup categories, in assignment order: an item is listed only in the first
/// category that matches it.
public enum CleanupCategory: String, Sendable, Codable, CaseIterable, Comparable {
    case duplicates, similar, blurry, screenshots, duplicateVideos, largeVideos

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Large Videos only informs; nothing in it starts selected (FR-010a).
    public var preselects: Bool { self != .largeVideos }
}

/// Metadata read from the photo library. No pixels.
public struct AssetMetadata: Sendable, Hashable {
    public var assetID: String
    public var kind: ItemKind
    public var captureDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var duration: Double?
    public var isFavorite: Bool
    public var hasAdjustments: Bool
    public var isPortrait: Bool
    public var isLongExposure: Bool
    public var burstID: String?
    public var albumNames: [String]

    public init(
        assetID: String, kind: ItemKind, captureDate: Date? = nil,
        modificationDate: Date? = nil, pixelWidth: Int, pixelHeight: Int,
        duration: Double? = nil, isFavorite: Bool = false, hasAdjustments: Bool = false,
        isPortrait: Bool = false, isLongExposure: Bool = false, burstID: String? = nil,
        albumNames: [String] = []
    ) {
        self.assetID = assetID
        self.kind = kind
        self.captureDate = captureDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
        self.isPortrait = isPortrait
        self.isLongExposure = isLongExposure
        self.burstID = burstID
        self.albumNames = albumNames
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }

    public var aspectRatio: Double {
        guard pixelHeight > 0 else { return 0 }
        return Double(pixelWidth) / Double(pixelHeight)
    }
}

/// Result of analyzing one preview image.
public struct Analysis: Sendable, Hashable {
    public var dHash: UInt64
    /// 32×32 grayscale miniature: confirms duplicates and similar shots.
    public var thumbprint: Data
    public var featurePrint: Data
    public var sharpness: Double
    public var aestheticsScore: Double?
    public var faceQuality: Double?

    public init(
        dHash: UInt64, thumbprint: Data = Data(), featurePrint: Data, sharpness: Double,
        aestheticsScore: Double? = nil, faceQuality: Double? = nil
    ) {
        self.dHash = dHash
        self.thumbprint = thumbprint
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.aestheticsScore = aestheticsScore
        self.faceQuality = faceQuality
    }
}

/// Cached analysis of one library item (data-model.md "LibraryItem").
public struct LibraryItem: Sendable, Hashable, Identifiable {
    public var metadata: AssetMetadata
    public var analysisSource: AnalysisSource
    public var analysis: Analysis?
    public var byteSize: Int64?
    public var isSizeEstimated: Bool
    public var analyzedAt: Date

    public var id: String { metadata.assetID }
    public var assetID: String { metadata.assetID }

    /// Analysis is always nil for items that were not scanned.
    public init(
        metadata: AssetMetadata, analysisSource: AnalysisSource, analysis: Analysis?,
        byteSize: Int64? = nil, isSizeEstimated: Bool = false, analyzedAt: Date = .now
    ) {
        self.metadata = metadata
        self.analysisSource = analysisSource
        self.analysis = analysisSource == .notScanned ? nil : analysis
        self.byteSize = byteSize
        self.isSizeEstimated = isSizeEstimated
        self.analyzedAt = analyzedAt
    }

    /// Measured size if known, otherwise an estimate.
    public var effectiveByteSize: Int64 { byteSize ?? SizeEstimator.estimate(metadata) }

    /// True when the size shown to the user is an estimate.
    public var sizeIsEstimate: Bool { byteSize == nil || isSizeEstimated }
}

/// Progress through the library, so a scan can resume (data-model.md "ScanSession").
public struct ScanSession: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: ScanKind
    public var state: ScanState
    public var startedAt: Date
    public var finishedAt: Date?
    public var totalItems: Int
    public var processedItems: Int
    public var notScannedCount: Int
    public var lastProcessedAssetID: String?

    public init(
        id: UUID = UUID(), kind: ScanKind, state: ScanState, startedAt: Date = .now,
        finishedAt: Date? = nil, totalItems: Int = 0, processedItems: Int = 0,
        notScannedCount: Int = 0, lastProcessedAssetID: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.totalItems = totalItems
        self.processedItems = processedItems
        self.notScannedCount = notScannedCount
        self.lastProcessedAssetID = lastProcessedAssetID
    }

    public var isActive: Bool { state == .running || state == .paused }
}

public struct ScanProgress: Sendable, Hashable {
    public var processed: Int
    public var total: Int
    public var notScanned: Int
    public var state: ScanState
    /// True while the scan waits for the phone to cool down.
    public var isThermalPaused: Bool

    public init(
        processed: Int, total: Int, notScanned: Int, state: ScanState,
        isThermalPaused: Bool = false
    ) {
        self.processed = processed
        self.total = total
        self.notScanned = notScanned
        self.state = state
        self.isThermalPaused = isThermalPaused
    }

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }
}
