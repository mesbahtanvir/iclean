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
    /// Not analyzed on purpose: in the free app videos are listed by file size only and no
    /// frame of a video is opened (video analysis is a Pro feature, `ProFeatures`). Unlike
    /// `notScanned` this is not a failure and is not counted as "not scanned". It is not
    /// retried either, until Pro is on and a full scan picks the video up (`ScanPlanner`).
    case metadataOnly

    /// Whether items from this source can carry an analysis.
    public var hasAnalysis: Bool { self != .notScanned && self != .metadataOnly }
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
    /// When the item was added to the Photos library (iOS 26 and later; nil before). A copy
    /// whose capture date equals this date was probably dated by when it was saved.
    public var addedDate: Date?
    /// Whether the item has a location (nil: not known yet, for items stored by an earlier version).
    /// Copies re-saved by messaging apps lose it.
    public var hasLocation: Bool?

    public init(
        assetID: String, kind: ItemKind, captureDate: Date? = nil,
        modificationDate: Date? = nil, pixelWidth: Int, pixelHeight: Int,
        duration: Double? = nil, isFavorite: Bool = false, hasAdjustments: Bool = false,
        isPortrait: Bool = false, isLongExposure: Bool = false, burstID: String? = nil,
        albumNames: [String] = [], addedDate: Date? = nil, hasLocation: Bool? = nil
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
        self.addedDate = addedDate
        self.hasLocation = hasLocation
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
/// Why an item could not be checked (003 FR-006 to FR-008).
public enum ScanFailure: String, Sendable, Codable {
    /// Analysis threw or the preview could not be produced.
    case transient
    /// Analysis took longer than the per-item limit.
    case timeout
    /// The app died twice while this item was being analyzed.
    case crashed
}

public struct LibraryItem: Sendable, Hashable, Identifiable {
    public var metadata: AssetMetadata
    public var analysisSource: AnalysisSource
    public var analysis: Analysis?
    public var byteSize: Int64?
    public var isSizeEstimated: Bool
    public var analyzedAt: Date
    /// Set when the item was given up on after repeated failures (003 FR-008).
    public var scanFailure: ScanFailure?
    /// How many scans have ended with this item not analyzed (003 FR-008).
    public var scanAttempts: Int

    public var id: String { metadata.assetID }
    public var assetID: String { metadata.assetID }

    /// Analysis is always nil for items that were not scanned or are metadata only.
    public init(
        metadata: AssetMetadata, analysisSource: AnalysisSource, analysis: Analysis?,
        byteSize: Int64? = nil, isSizeEstimated: Bool = false, analyzedAt: Date = .now,
        scanFailure: ScanFailure? = nil, scanAttempts: Int = 0
    ) {
        self.metadata = metadata
        self.analysisSource = analysisSource
        self.analysis = analysisSource.hasAnalysis ? analysis : nil
        self.byteSize = byteSize
        self.isSizeEstimated = isSizeEstimated
        self.analyzedAt = analyzedAt
        self.scanFailure = analysisSource == .notScanned ? scanFailure : nil
        self.scanAttempts = scanAttempts
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
    /// Items counted as processed before this job's chunks existed (a scan started by
    /// an app version without chunks, 003 FR-014).
    public var baseProcessed: Int
    /// Items given up on after repeated failures (003 FR-006).
    public var failedItems: Int
    /// Times the app died while a chunk of this job was running (003 FR-005).
    public var crashCount: Int
    /// Times this job was resumed after the app died; a catch-up for library changes
    /// runs when it is above zero (003 FR-011).
    public var interruptedCount: Int

    public init(
        id: UUID = UUID(), kind: ScanKind, state: ScanState, startedAt: Date = .now,
        finishedAt: Date? = nil, totalItems: Int = 0, processedItems: Int = 0,
        notScannedCount: Int = 0, lastProcessedAssetID: String? = nil,
        baseProcessed: Int = 0, failedItems: Int = 0, crashCount: Int = 0,
        interruptedCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.totalItems = totalItems
        self.processedItems = processedItems
        self.baseProcessed = baseProcessed
        self.failedItems = failedItems
        self.crashCount = crashCount
        self.interruptedCount = interruptedCount
        self.notScannedCount = notScannedCount
        self.lastProcessedAssetID = lastProcessedAssetID
    }

    public var isActive: Bool { state == .running || state == .paused }
}

/// Why a scan is paused (002 data-model.md).
public enum ScanPauseReason: String, Sendable, Codable {
    /// The user tapped Pause inside the app.
    case user
    /// The system's progress display was stopped, by the user or by the system, while
    /// the app was in the background. Stays paused until the user taps Resume.
    case stoppedOutsideApp
    /// The app ran out of background time. Resumes by itself when the app is back.
    case backgroundLimit
}

public struct ScanProgress: Sendable, Hashable {
    public var processed: Int
    public var total: Int
    public var notScanned: Int
    public var state: ScanState
    /// True while the scan waits for the phone to cool down.
    public var isThermalPaused: Bool
    /// Non-nil only while `state == .paused`.
    public var pauseReason: ScanPauseReason?
    /// Items that could not be checked after repeated failures; a subset of
    /// `notScanned` (003 FR-008).
    public var failed: Int

    public init(
        processed: Int, total: Int, notScanned: Int, state: ScanState,
        isThermalPaused: Bool = false, pauseReason: ScanPauseReason? = nil, failed: Int = 0
    ) {
        self.processed = processed
        self.total = total
        self.notScanned = notScanned
        self.state = state
        self.isThermalPaused = isThermalPaused
        self.pauseReason = pauseReason
        self.failed = failed
    }

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    /// A scan paused only because the app lost background time continues by itself
    /// when the app returns to the foreground (002 FR-009).
    public var resumesOnForeground: Bool { state == .paused && pauseReason == .backgroundLimit }
}
