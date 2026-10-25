import Foundation

/// Bumped by a person whenever a change to the detectors, their thresholds, `KeeperRules` or
/// `DateCredibility` could change what a build produces. A saved snapshot built under another
/// number is never shown. `BaselineHostTests` pins the groups and kept copies the builder produces on the baseline library, so a
/// behaviour change that forgets to bump this fails a test.
public enum BuilderVersion {
    public static let current = 1
}

/// Everything besides the store's revision that decides whether a saved snapshot may be shown.
public struct BuilderKey: Codable, Equatable, Sendable {
    public var builderVersion: Int
    /// Every threshold the detectors and keeper rules use, so changing one invalidates saved
    /// results by itself, whether or not anyone remembers to bump `BuilderVersion`.
    public var thresholds: String
    public var detectors: [String]
    public var access: String
    public var timeZone: String
    public var calendar: String
    /// The level chosen for each category with levels (spec 011); changing one rebuilds the results.
    public var levels: String?

    public init(
        detectors: [CleanupCategory], access: LibraryAccess,
        calendar: Calendar = .current, levels: ResultLevels? = nil
    ) {
        builderVersion = BuilderVersion.current
        thresholds = Self.currentThresholds
        self.detectors = detectors.map(\.rawValue)
        self.access = access.rawValue
        timeZone = calendar.timeZone.identifier
        self.calendar = "\(calendar.identifier)"
        self.levels = (levels ?? ResultLevels()).key
    }
}

extension BuilderKey {
    static var currentThresholds: String {
        [
            "dup", "\(DuplicateThresholds.hashDistance)", "\(DuplicateThresholds.thumbprint)",
            "\(DuplicateThresholds.brightness)", "\(DuplicateThresholds.aspectRatio)",
            "sim", "\(SimilarThresholds.window)", "\(SimilarThresholds.thumbprint)",
            "\(SimilarThresholds.featurePrint)", "\(SimilarThresholds.featurePrintAgreement)",
            "\(SimilarThresholds.tightFeaturePrint)", "\(SimilarThresholds.tightThumbprint)",
            "\(SimilarThresholds.tightThumbprintWithoutPrint)", "\(SimilarThresholds.wideFeaturePrint)",
            "\(SimilarThresholds.wideThumbprint)", "\(SimilarThresholds.wideThumbprintWithoutPrint)",
            "blur", "\(BlurThresholds.sharpness)", "\(BlurThresholds.aesthetics)",
            "unimp", "\(UnimportantThresholds.softSharpness)", "\(UnimportantThresholds.veryShaky)",
            "\(UnimportantThresholds.shaky)", "\(UnimportantThresholds.alonePoints)",
            "\(UnimportantThresholds.noLocationPoints)", "\(UnimportantThresholds.lowAestheticsPoints)",
            "\(UnimportantThresholds.tight)", "\(UnimportantThresholds.medium)",
            "\(UnimportantThresholds.wide)",
            "vid", "\(LargeVideosCategory.limit)",
            "date", "\(DateThresholds.sameMoment)", "\(DateThresholds.savedWindow)",
            "\(DateThresholds.preservedGap)", "\(DateThresholds.sharedStampCount)",
            "\(DateThresholds.farFromEarliest)", "\(DateThresholds.futureSlack)",
            "\(DateThresholds.impossibleWeight)",
        ].joined(separator: "|")
    }
}

/// The slim results the screens show, as saved. Holds ids, structure and the little metadata the
/// lists display; never a thumbprint, a feature print or a hash (those stay in the store).
public struct ResultsSnapshot: Codable, Sendable {
    public static let formatVersion = 1

    public struct Header: Codable, Equatable, Sendable {
        public var formatVersion: Int
        public var builderKey: BuilderKey
        public var builtAt: Date
        public var itemCount: Int
        public var keepMarkCount: Int
    }

    public struct Item: Codable, Sendable {
        var assetID: String
        var kind: String
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
        var addedDate: Date?
        var hasLocation: Bool?
        var analysisSource: String
        var sharpness: Double?
        var aestheticsScore: Double?
        var faceQuality: Double?
        var byteSize: Int64?
        var isSizeEstimated: Bool
    }

    public struct Group: Codable, Sendable {
        var type: GroupType
        var members: [String]
        var keepers: [String]
        var confidence: Confidence
        var dateNotes: [String: [DateReason]]
    }

    public struct Category: Codable, Sendable {
        var category: CleanupCategory
        var groups: [Group]
        /// Spec 011; absent in snapshots saved before it.
        var level: ResultLevel?
        var levels: [LevelSummary]?
    }

    public var header: Header
    public var categories: [Category]
    public var defaultSelection: [String]
    public var notScannedCount: Int
    public var items: [Item]

    /// Snapshots `results` (any shape: only group members are kept).
    public init(
        results: CleanupResults, builderKey: BuilderKey, itemCount: Int, keepMarkCount: Int,
        builtAt: Date = .now
    ) {
        header = Header(
            formatVersion: Self.formatVersion, builderKey: builderKey, builtAt: builtAt,
            itemCount: itemCount, keepMarkCount: keepMarkCount)
        categories = results.categories.map { c in
            Category(
                category: c.category,
                groups: c.groups.map {
                    Group(
                        type: $0.type, members: $0.members, keepers: $0.keepers.sorted(),
                        confidence: $0.confidence, dateNotes: $0.dateNotes)
                }, level: c.level, levels: c.levels.isEmpty ? nil : c.levels)
        }
        defaultSelection = results.defaultSelection.sorted()
        notScannedCount = results.notScannedCount
        let members = Set(results.categories.flatMap(\.allMembers))
        items = members.sorted().compactMap { id in results.items[id].map(Item.init) }
    }

    /// The results this snapshot saved. Items are slim (no fingerprints).
    public func results() -> CleanupResults {
        let cats = categories.map { c in
            CategoryResult(
                category: c.category,
                groups: c.groups.map {
                    ResultGroup(
                        type: $0.type, members: $0.members, keepers: Set($0.keepers),
                        confidence: $0.confidence, dateNotes: $0.dateNotes)
                }, level: c.level, levels: c.levels ?? [])
        }
        var byID: [String: LibraryItem] = [:]
        for item in items { byID[item.assetID] = item.libraryItem }
        return CleanupResults(
            categories: cats, defaultSelection: Set(defaultSelection),
            notScannedCount: notScannedCount, items: byID)
    }
}

extension ResultsSnapshot.Item {
    init(_ item: LibraryItem) {
        let m = item.metadata
        assetID = m.assetID
        kind = m.kind.rawValue
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
        analysisSource = item.analysisSource.rawValue
        sharpness = item.analysis?.sharpness
        aestheticsScore = item.analysis?.aestheticsScore
        faceQuality = item.analysis?.faceQuality
        byteSize = item.byteSize
        isSizeEstimated = item.isSizeEstimated
    }

    var libraryItem: LibraryItem {
        let metadata = AssetMetadata(
            assetID: assetID, kind: ItemKind(rawValue: kind) ?? .photo, captureDate: captureDate,
            modificationDate: modificationDate, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            duration: duration, isFavorite: isFavorite, hasAdjustments: hasAdjustments,
            isPortrait: isPortrait, isLongExposure: isLongExposure, burstID: burstID,
            albumNames: albumNames, addedDate: addedDate, hasLocation: hasLocation)
        let source = AnalysisSource(rawValue: analysisSource) ?? .notScanned
        var analysis: Analysis?
        if let sharpness {
            analysis = Analysis(
                dHash: 0, thumbprint: Data(), featurePrint: Data(), sharpness: sharpness,
                aestheticsScore: aestheticsScore, faceQuality: faceQuality)
        }
        // `analyzedAt` is bookkeeping a slim item does not carry; a fixed value keeps a restore
        // and a slimmed build equal.
        return LibraryItem(
            metadata: metadata, analysisSource: source, analysis: analysis, byteSize: byteSize,
            isSizeEstimated: isSizeEstimated, analyzedAt: Date(timeIntervalSince1970: 0))
    }
}

extension CleanupResults {
    /// The shape results have after a restore: only group members, and no fingerprints. A build
    /// and a restore then give the same thing, and a session no longer holds every item's blobs.
    public func slimmed() -> CleanupResults {
        ResultsSnapshot(
            results: self,
            builderKey: BuilderKey(detectors: [], access: .full),
            itemCount: 0, keepMarkCount: 0
        ).results()
    }
}

/// Decides whether a saved snapshot may be shown, and gives its results.
public enum SnapshotRestore {
    /// How old a snapshot may be before it is rebuilt anyway. It bounds the inputs that depend on
    /// the clock (a future date) and any bump a write path might have missed.
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    public enum Outcome: Equatable, Sendable {
        case restored
        case rejected(Reason)
    }

    public enum Reason: Equatable, Sendable {
        case none
        case version
        case revision
        case damaged
        case builder
        case counts
        case age
    }

    public static func restore(
        _ envelope: StateEnvelope?, expecting key: BuilderKey, revision: Int64, itemCount: Int,
        keepMarkCount: Int, now: Date = .now
    ) -> (results: CleanupResults?, builtAt: Date?, outcome: Outcome) {
        guard let envelope else { return (nil, nil, .rejected(.none)) }
        guard envelope.version == ResultsSnapshot.formatVersion else {
            return (nil, nil, .rejected(.version))
        }
        guard envelope.basedOnRevision == revision else { return (nil, nil, .rejected(.revision)) }
        guard let snapshot = try? StateCodec.open(envelope.payload, as: ResultsSnapshot.self) else {
            return (nil, nil, .rejected(.damaged))
        }
        let h = snapshot.header
        guard h.formatVersion == ResultsSnapshot.formatVersion else {
            return (nil, nil, .rejected(.version))
        }
        guard h.builderKey == key else { return (nil, nil, .rejected(.builder)) }
        guard h.itemCount == itemCount, h.keepMarkCount == keepMarkCount else {
            return (nil, nil, .rejected(.counts))
        }
        guard now.timeIntervalSince(h.builtAt) <= maxAge else { return (nil, nil, .rejected(.age)) }
        return (snapshot.results(), h.builtAt, .restored)
    }
}
