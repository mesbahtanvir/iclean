import Foundation

// Boundary value types crossing the PhotoKit boundary. Everything above the
// gateway is Sendable value types — SCAN_PIPELINE.md §12.

public enum MediaKind: Int, Sendable, Codable, Hashable {
    case image = 1
    case video = 2
}

public struct AssetSubtypes: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let screenshot = AssetSubtypes(rawValue: 1 << 0)
    public static let panorama = AssetSubtypes(rawValue: 1 << 1)
    public static let hdr = AssetSubtypes(rawValue: 1 << 2)
    public static let livePhoto = AssetSubtypes(rawValue: 1 << 3)
    public static let slomo = AssetSubtypes(rawValue: 1 << 4)
    public static let timelapse = AssetSubtypes(rawValue: 1 << 5)
    public static let depthEffect = AssetSubtypes(rawValue: 1 << 6)
}

/// unknown / local / evicted — split probes per SCAN_PIPELINE.md §5-S2:
/// thumbnail availability and original availability are independent facts.
public enum Availability: Int, Sendable, Codable, Hashable {
    case unknown = 0
    case local = 1
    case evicted = 2
}

/// ~1 km grid bucket. We never persist precise coordinates (SCAN_PIPELINE.md §5-S1).
public struct LocationBucket: Sendable, Codable, Hashable {
    public let lat: Int
    public let lon: Int
    public init(lat: Int, lon: Int) {
        self.lat = lat
        self.lon = lon
    }

    /// Chebyshev distance — session splitting uses > 1 so photos straddling
    /// a cell edge never split a session (SCAN_PIPELINE.md §6.1).
    public func chebyshev(to other: LocationBucket) -> Int {
        max(abs(lat - other.lat), abs(lon - other.lon))
    }
}

public struct AssetStub: Sendable, Codable, Hashable, Identifiable {
    public let id: String // PHAsset.localIdentifier
    public let mediaKind: MediaKind
    public let subtypes: AssetSubtypes
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public let isFavorite: Bool
    public let burstId: String?
    public let representsBurst: Bool
    public let isBurstUserPick: Bool
    public let locationBucket: LocationBucket?

    public init(
        id: String,
        mediaKind: MediaKind,
        subtypes: AssetSubtypes = [],
        createdAt: Date?,
        modifiedAt: Date? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval = 0,
        isFavorite: Bool = false,
        burstId: String? = nil,
        representsBurst: Bool = false,
        isBurstUserPick: Bool = false,
        locationBucket: LocationBucket? = nil
    ) {
        self.id = id
        self.mediaKind = mediaKind
        self.subtypes = subtypes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.isFavorite = isFavorite
        self.burstId = burstId
        self.representsBurst = representsBurst
        self.isBurstUserPick = isBurstUserPick
        self.locationBucket = locationBucket
    }
}

/// Grayscale, row-major, width × height bytes. All cheap pixel math (S2) and
/// hashing consume this; the gateway owns decode + downsample + gray conversion.
public struct GrayThumbnail: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel buffer size mismatch")
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum ThumbnailResult: Sendable {
    case ok(GrayThumbnail)
    /// Single callback, nil image, PHImageResultIsInCloudKey — SCAN_PIPELINE.md §5-S2.
    case needsConnection
    case failed(String)
}

public struct ResourceInfo: Sendable, Codable, Hashable {
    public let filename: String?
    public let uti: String?
    public let fileSize: Int64?
    /// True when fileSize came from the dimensions×format estimate, not the KVC key.
    public let fileSizeIsEstimate: Bool
    public let isEdited: Bool
    public let hasRawResource: Bool

    public init(
        filename: String?,
        uti: String?,
        fileSize: Int64?,
        fileSizeIsEstimate: Bool,
        isEdited: Bool,
        hasRawResource: Bool
    ) {
        self.filename = filename
        self.uti = uti
        self.fileSize = fileSize
        self.fileSizeIsEstimate = fileSizeIsEstimate
        self.isEdited = isEdited
        self.hasRawResource = hasRawResource
    }
}

/// One processed batch of library changes; `token` is persisted in the same
/// transaction as the batch's rows (SCAN_PIPELINE.md §9).
public struct ChangeSet: Sendable {
    public let inserted: [AssetStub]
    public let updated: [AssetStub]
    public let deletedIds: [String]
    public let token: Data?

    public init(inserted: [AssetStub], updated: [AssetStub], deletedIds: [String], token: Data?) {
        self.inserted = inserted
        self.updated = updated
        self.deletedIds = deletedIds
        self.token = token
    }
}

public struct AlbumInfo: Sendable, Hashable {
    public let id: String
    public let title: String
    public let memberIds: [String]

    public init(id: String, title: String, memberIds: [String]) {
        self.id = id
        self.title = title
        self.memberIds = memberIds
    }
}

/// Vision-derived per-asset signals. `eyesOpenMin` is DERIVED from eye-landmark
/// geometry (custom, tunable) — not an Apple output. SCAN_PIPELINE.md §5-S4.
public struct VisionSignals: Sendable, Codable, Hashable {
    public let faceCount: Int
    public let bestFaceQuality: Double?
    public let eyesOpenMin: Double?
    public let saliencyBox: SaliencyBox?

    public init(faceCount: Int, bestFaceQuality: Double?, eyesOpenMin: Double?, saliencyBox: SaliencyBox?) {
        self.faceCount = faceCount
        self.bestFaceQuality = bestFaceQuality
        self.eyesOpenMin = eyesOpenMin
        self.saliencyBox = saliencyBox
    }
}

public struct SaliencyBox: Sendable, Codable, Hashable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
}

/// Transient embedding distances for one session window. VNFeaturePrintObservation
/// never crosses this boundary; embeddings are discarded after clustering
/// (SCAN_PIPELINE.md §6.3).
public struct FeatureDistanceComputer: Sendable {
    public let visionRevision: Int
    private let compute: @Sendable (String, String) -> Double?

    public init(visionRevision: Int, compute: @escaping @Sendable (String, String) -> Double?) {
        self.visionRevision = visionRevision
        self.compute = compute
    }

    /// Returns nil when either asset has no embedding (failed S4).
    public func distance(_ a: String, _ b: String) -> Double? {
        compute(a, b)
    }
}

// MARK: - Commit boundary (APP_PLATFORM.md §2)

/// One atomic performChanges block: keeper inheritance AND deletion together,
/// so user-cancel rolls back everything — orphaned metadata is impossible.
public struct CommitChunkPlan: Sendable, Codable, Hashable {
    public struct AlbumAdd: Sendable, Codable, Hashable {
        public let albumId: String
        public let keeperId: String
        public init(albumId: String, keeperId: String) {
            self.albumId = albumId
            self.keeperId = keeperId
        }
    }

    public let albumAdds: [AlbumAdd]
    public let favoriteKeeperIds: [String]
    public let deleteIds: [String]

    public init(albumAdds: [AlbumAdd], favoriteKeeperIds: [String], deleteIds: [String]) {
        self.albumAdds = albumAdds
        self.favoriteKeeperIds = favoriteKeeperIds
        self.deleteIds = deleteIds
    }
}

public enum CommitChunkError: Error, Sendable {
    /// The user cancelled the system confirmation dialog. The whole chunk rolled back.
    case userCancelled
    case photoKit(String)
}
