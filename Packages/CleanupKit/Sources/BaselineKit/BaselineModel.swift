import Foundation

/// What kind of file an asset is.
public enum BaselineKind: String, Codable, Sendable {
    case photo, screenshot, video
}

/// The result category an asset is expected to land in. `none` marks a control: an asset
/// that must not be flagged by anything.
public enum BaselineCategory: String, Codable, Sendable {
    case duplicates, similar, blurry, screenshots, largeVideos, none
}

/// How to draw one asset, deterministically: a base image, then edits, then a file format.
/// The same recipe renders the same pixels on every device and every run.
public struct BaselineRecipe: Codable, Hashable, Sendable {
    public enum Base: Codable, Hashable, Sendable {
        /// A detailed scene of random shapes and sensor-like grain.
        case scene(seed: UInt64)
        /// A sharp but featureless scene, like a clear sky over a wall.
        case lowTexture(seed: UInt64)
        /// Bands and a checkerboard: screenshot-like.
        case stripes(seed: UInt64, width: Int, height: Int)
        /// One frame of a burst: the camera drifts and a subject walks across.
        case burstFrame(sceneSeed: UInt64, index: Int)
        /// A short clip with a subject moving across a scene.
        case video(seed: UInt64, seconds: Double)
    }

    public enum Step: Codable, Hashable, Sendable {
        case resize(Double)
        /// A JPEG round trip at this quality: what messaging apps do.
        case recompress(Double)
        /// Keep the centre part: an edit, not a duplicate.
        case crop(Double)
        /// Shrink then enlarge by this factor: out of focus.
        case blur(Double)
        /// Average along the horizontal by this many pixels: camera shake.
        case motionBlur(Int)
    }

    public enum Format: Codable, Hashable, Sendable {
        case jpeg(quality: Double)
        case png
        case mov(width: Int, height: Int, bitrate: Int)

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .png: "png"
            case .mov: "mov"
            }
        }
    }

    public var base: Base
    public var steps: [Step]
    public var format: Format

    public init(base: Base, steps: [Step] = [], format: Format) {
        self.base = base
        self.steps = steps
        self.format = format
    }
}

/// One asset of the baseline library and what the app is expected to do with it.
public struct BaselineAsset: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, for example `dup-A1`.
    public var id: String
    /// The file name the asset gets in the Photos library; it is how an imported asset is
    /// recognised again, on any device. It includes the catalog version, because an asset that
    /// is already in the library is reused as it is, whatever its recipe now says.
    public var filename: String
    public var kind: BaselineKind
    public var recipe: BaselineRecipe
    public var captureDate: Date
    public var favorite: Bool
    /// Extra albums besides the baseline album.
    public var albums: [String]
    public var expected: BaselineCategory
    /// The expected group, for grouped categories.
    public var group: String?
    /// Whether this asset is the expected keeper of its group.
    public var keeper: Bool
    /// Whether the keeper is checked for this group (similar shots pick by sharpness, which
    /// is not worth asserting).
    public var checkKeeper: Bool
    /// Whether the asset is given a location when it is imported.
    public var location: Bool
    /// Why the asset exists.
    public var note: String
    /// Reported but never asserted: a known gap in the app, kept so progress on it shows up
    /// in the reports of every device.
    public var informational: Bool

    public init(
        id: String, filename: String, kind: BaselineKind, recipe: BaselineRecipe,
        captureDate: Date, favorite: Bool = false, albums: [String] = [],
        expected: BaselineCategory, group: String? = nil, keeper: Bool = false,
        checkKeeper: Bool = false, location: Bool = false, note: String, informational: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.recipe = recipe
        self.captureDate = captureDate
        self.favorite = favorite
        self.albums = albums
        self.expected = expected
        self.group = group
        self.keeper = keeper
        self.checkKeeper = checkKeeper
        self.location = location
        self.note = note
        self.informational = informational
    }
}

/// A versioned set of assets with known expected results.
public struct BaselineCatalog: Codable, Sendable {
    public var version: Int
    public var name: String
    /// Every asset is added to this album, so the library can find and remove them.
    public var albumTitle: String
    public var assets: [BaselineAsset]

    public init(version: Int, name: String, albumTitle: String, assets: [BaselineAsset]) {
        self.version = version
        self.name = name
        self.albumTitle = albumTitle
        self.assets = assets
    }

    public func asset(id: String) -> BaselineAsset? { assets.first { $0.id == id } }

    /// Expected groups of one category: group id to member ids.
    public func groups(_ category: BaselineCategory) -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for a in assets where a.expected == category {
            if let g = a.group { out[g, default: []].insert(a.id) }
        }
        return out
    }

    /// Assets that nothing may flag.
    public var controls: [BaselineAsset] { assets.filter { $0.expected == .none } }
}
