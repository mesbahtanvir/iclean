import Foundation

/// What kind of library item this is.
public enum ItemKind: String, Sendable, Codable, CaseIterable {
    case photo, screenshot, video, livePhoto
    /// A video the system recorded of the screen (spec 015). Listed from metadata alone, like a
    /// screenshot; a video for everything that opens frames.
    case screenRecording

    public var isVideo: Bool { self == .video || self == .screenRecording }
    public var isStillImage: Bool { !isVideo }
}

/// What the person did with a frame of a burst in the Photos app (spec 015 FR-002).
public enum BurstPick: String, Sendable, Codable {
    /// The person chose this frame in the burst picker.
    case userPick
    /// Photos chose it as the best frame.
    case autoPick
    case none
}

/// What listing an item in a category leads to (spec 015 FR-007).
public enum CategoryAction: String, Sendable, Codable {
    /// The selected items go to Recently Deleted.
    case remove
    /// The selected Live Photos are replaced by their stills; the originals go to Recently Deleted.
    case trim
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
    case duplicates, bursts, similar, blurry, dark, unimportant, screenshots, screenRecordings,
        duplicateVideos, largeVideos
    /// The one category that is not a removal (spec 015): an item may be here and in a removal
    /// category at once.
    case livePhotos

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    public var action: CategoryAction { self == .livePhotos ? .trim : .remove }

    /// Whether every item the category lists is a video. The screens then say "video" and lay the
    /// items out as a list with length and size.
    public var listsVideos: Bool {
        self == .largeVideos || self == .duplicateVideos || self == .screenRecordings
    }

    /// Large Videos, Unimportant, Screen Recordings and Live Photos only inform; nothing in them
    /// starts selected (001 FR-010a, 011 FR-004, 015).
    public var preselects: Bool {
        switch self {
        case .largeVideos, .unimportant, .screenRecordings, .livePhotos: false
        default: true
        }
    }
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
    /// What the person did with this burst frame in Photos; nil for items stored before spec 015.
    public var burstPick: BurstPick?
    /// The frame Photos shows for the burst.
    public var representsBurst: Bool
    /// From a shared album (another person's, or shared with others); never changed in place.
    public var isShared: Bool
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
        burstPick: BurstPick? = nil, representsBurst: Bool = false, isShared: Bool = false,
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
        self.burstPick = burstPick
        self.representsBurst = representsBurst
        self.isShared = isShared
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
    /// The share of the preview at the dark or bright extreme (spec 015 Dark); nil before the
    /// photo was read for it.
    public var emptiness: Double?
    /// Whether the photo shows nothing: at the extremes with no structure (`Emptiness`).
    public var isEmpty: Bool?
    /// Vision work the analyzer was told not to do because no detector can read it for this photo
    /// (spec 010). Distinct from a request that failed, which leaves an empty print and nothing here.
    public var skippedVision: VisionWork

    public init(
        dHash: UInt64, thumbprint: Data = Data(), featurePrint: Data, sharpness: Double,
        aestheticsScore: Double? = nil, faceQuality: Double? = nil, emptiness: Double? = nil,
        isEmpty: Bool? = nil, skippedVision: VisionWork = []
    ) {
        self.dHash = dHash
        self.thumbprint = thumbprint
        self.featurePrint = featurePrint
        self.sharpness = sharpness
        self.aestheticsScore = aestheticsScore
        self.faceQuality = faceQuality
        self.emptiness = emptiness
        self.isEmpty = isEmpty
        self.skippedVision = skippedVision
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
    /// The bytes of a Live Photo's movie, part of `byteSize` (spec 015); nil when unknown or none.
    public var motionByteSize: Int64?
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
        byteSize: Int64? = nil, motionByteSize: Int64? = nil, isSizeEstimated: Bool = false,
        analyzedAt: Date = .now, scanFailure: ScanFailure? = nil, scanAttempts: Int = 0
    ) {
        self.metadata = metadata
        self.analysisSource = analysisSource
        self.analysis = analysisSource.hasAnalysis ? analysis : nil
        self.byteSize = byteSize
        self.motionByteSize = motionByteSize
        self.isSizeEstimated = isSizeEstimated
        self.analyzedAt = analyzedAt
        self.scanFailure = analysisSource == .notScanned ? scanFailure : nil
        self.scanAttempts = scanAttempts
    }

    /// The item without its stored fingerprints (the miniature and the feature print), which only
    /// detection reads. Results keep items this way: the fingerprints of a 30,000-photo library
    /// are most of its memory, and the screens never look at them (spec 008).
    public var withoutFingerprints: LibraryItem {
        var copy = self
        copy.analysis?.thumbprint = Data()
        copy.analysis?.featurePrint = Data()
        // Which Vision work the scan left out is bookkeeping for the scan, not for a screen.
        copy.analysis?.skippedVision = []
        return copy
    }

    /// Measured size if known, otherwise an estimate.
    public var effectiveByteSize: Int64 { byteSize ?? SizeEstimator.estimate(metadata) }

    /// True when the size shown to the user is an estimate.
    public var sizeIsEstimate: Bool { byteSize == nil || isSizeEstimated }

    /// What the still alone takes: the whole asset less its movie (spec 015 Live Photos).
    public var stillByteSize: Int64 { max(0, effectiveByteSize - (motionByteSize ?? 0)) }
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
    /// Saving progress failed several times in a row (a full disk, for one). Stays paused until
    /// the user taps Resume, because going on without saving would lose the results.
    case storageUnavailable
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
    /// Grows whenever the stored results changed enough to be worth showing again: the quick
    /// wins were stored, or a block of photos was finished and saved (spec 008). A screen that
    /// rebuilds results compares it with the last value it acted on.
    public var publishedRevision: Int

    public init(
        processed: Int, total: Int, notScanned: Int, state: ScanState,
        isThermalPaused: Bool = false, pauseReason: ScanPauseReason? = nil, failed: Int = 0,
        publishedRevision: Int = 0
    ) {
        self.processed = processed
        self.total = total
        self.notScanned = notScanned
        self.state = state
        self.isThermalPaused = isThermalPaused
        self.pauseReason = pauseReason
        self.failed = failed
        self.publishedRevision = publishedRevision
    }

    public var fraction: Double { total == 0 ? 1 : Double(processed) / Double(total) }

    /// A scan paused only because the app lost background time continues by itself
    /// when the app returns to the foreground (002 FR-009).
    public var resumesOnForeground: Bool { state == .paused && pauseReason == .backgroundLimit }
}
