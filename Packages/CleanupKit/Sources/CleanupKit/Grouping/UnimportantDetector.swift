import Foundation

/// Thresholds for unimportant photos (spec 011). All starting values, to be calibrated on real libraries
/// (`ScaleBench --levels-profile`); none of them is research.
public enum UnimportantThresholds {
    /// A photo is a candidate only if it is this soft or softer (0 blurred … 1 sharp): the shaky ones.
    public static let softSharpness = 0.70
    /// Below this the photo is badly shaken (3 points); below `shaky` it is shaky (2); otherwise soft (1).
    public static let veryShaky = 0.55
    public static let shaky = 0.62
    /// Points for a photo with no other photo within the similar-shots window: a lone shot, not one of a series.
    public static let alonePoints = 2
    /// Points for a photo with no location: saved or forwarded rather than shot.
    public static let noLocationPoints = 1
    /// Points when a known aesthetics score is below zero. Only photos near the blur threshold have one.
    public static let lowAestheticsPoints = 2
    /// Score needed for each level: Most likely, Probably, Maybe.
    public static let tight = 7
    public static let medium = 5
    public static let wide = 3

    static func cutoff(_ level: ResultLevel) -> Int {
        switch level {
        case .tight: tight
        case .medium: medium
        case .wide: wide
        }
    }
}

/// Photos that probably do not matter: shaky, about no person, taken alone, saved with no album, edit or
/// location (spec 011). A first version: it uses only what the scan already stores, so it cannot tell a pet,
/// a landscape or a whiteboard from a random object. Nothing in it is preselected.
///
/// A photo is listed only if none of these protects it, whatever its score: a face was found, Vision never ran
/// (so "no face" would mean nothing), portrait mode, a long exposure, a favourite, an album, an edit.
public struct UnimportantDetector: CategoryDetector {
    public let category = CleanupCategory.unimportant
    public let needsAnalysis = true
    /// The level to list; nil lists the default, `medium`.
    let levels: ResultLevels?

    public init(levels: ResultLevels? = nil) { self.levels = levels }

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        detectLevelled(items: items, all: items).groups
    }

    public func detectLevelled(items: [LibraryItem], all: [LibraryItem]) -> LevelledDetection {
        let chosen = levels?[.unimportant] ?? CleanupCategory.unimportant.defaultLevel
        // The loader reads feature prints only for photos with a neighbour, so a photo's own print cannot say
        // whether Vision worked. If Vision worked for any photo here, it worked for the library.
        let visionRan = all.contains { !($0.analysis?.featurePrint.isEmpty ?? true) }
        let withNeighbour = Self.photosWithNeighbour(all)
        var scored: [(item: LibraryItem, score: Int)] = []
        if visionRan {
            for item in items {
                if let score = Self.score(item, hasNeighbour: withNeighbour.contains(item.assetID))
                {
                    scored.append((item, score))
                }
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let da = $0.item.metadata.captureDate ?? .distantPast
            let db = $1.item.metadata.captureDate ?? .distantPast
            return da != db ? da < db : $0.item.assetID < $1.item.assetID
        }
        let summaries = ResultLevel.allCases.map { level -> LevelSummary in
            let count = scored.filter { $0.score >= UnimportantThresholds.cutoff(level) }.count
            return LevelSummary(level: level, groups: count, photos: count, removable: count)
        }
        let cutoff = UnimportantThresholds.cutoff(chosen)
        let groups = scored.filter { $0.score >= cutoff }.map { entry in
            ResultGroup(
                type: .single, members: [entry.item.assetID],
                confidence: entry.item.analysisSource == .cloudPreview ? .lower : .normal)
        }
        return LevelledDetection(groups: groups, level: chosen, levels: summaries)
    }

    /// The score of a photo, or nil if it may not be listed at all.
    static func score(_ item: LibraryItem, hasNeighbour: Bool) -> Int? {
        let m = item.metadata
        guard m.kind == .photo || m.kind == .livePhoto, let analysis = item.analysis else {
            return nil
        }
        guard !m.isPortrait, !m.isLongExposure, !m.isFavorite, !m.hasAdjustments,
            m.albumNames.isEmpty,
            analysis.faceQuality == nil, analysis.sharpness < UnimportantThresholds.softSharpness
        else { return nil }
        var points: Int
        switch analysis.sharpness {
        case ..<UnimportantThresholds.veryShaky: points = 3
        case ..<UnimportantThresholds.shaky: points = 2
        default: points = 1
        }
        if m.captureDate != nil, !hasNeighbour { points += UnimportantThresholds.alonePoints }
        if m.hasLocation == false { points += UnimportantThresholds.noLocationPoints }
        if let aesthetics = analysis.aestheticsScore, aesthetics < BlurThresholds.aesthetics {
            points += UnimportantThresholds.lowAestheticsPoints
        }
        return points
    }

    /// Photos with another photo within the similar-shots window, among everything being examined: an earlier
    /// category may have taken the neighbour away, which does not make the photo lonely.
    static func photosWithNeighbour(_ all: [LibraryItem]) -> Set<String> {
        let dated = all.compactMap { item -> (id: String, date: Date)? in
            let m = item.metadata
            guard m.kind == .photo || m.kind == .livePhoto, let date = m.captureDate else {
                return nil
            }
            return (m.assetID, date)
        }.sorted { $0.date < $1.date }
        var out = Set<String>()
        for i in dated.indices where i + 1 < dated.count {
            if dated[i + 1].date.timeIntervalSince(dated[i].date) <= SimilarThresholds.window {
                out.insert(dated[i].id)
                out.insert(dated[i + 1].id)
            }
        }
        return out
    }
}
