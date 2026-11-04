import Foundation
import Testing

@testable import CleanupKit

/// Spec 017: properties of `ScanPlanner.plan`, checked on seeded random libraries and stores instead of
/// hand-picked ones. The expected plan is worked out again here the slow way (every pair of photos, every
/// stored item) so that the planner's binary searches and shortcuts are compared with the plain
/// definition, not with themselves. A failing seed is printed and can be replayed.
@Suite struct PlannerPropertyTests {
    static let seeds: [UInt64] = Array(1...150)
    static let t0 = 1_600_000_000.0

    // MARK: Random worlds

    fileprivate struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    fileprivate static func chance(_ percent: Int, _ rng: inout SplitMix) -> Bool {
        Int.random(in: 0..<100, using: &rng) < percent
    }

    struct World {
        var library: [AssetMetadata]
        var stored: [StoredItemSummary]
    }

    /// Photos in clusters (seconds apart, a minute or so apart, hours apart), some bursts, favourites,
    /// albums, screenshots and videos; a store that holds part of it, in every state a store can be in.
    static func world(seed: UInt64, stored withStore: Bool) -> World {
        var rng = SplitMix(state: seed &* 0xD1B5_4A32_D192_ED03 &+ 7)
        var clock = 0.0
        var library: [AssetMetadata] = []
        let count = Int.random(in: 4...60, using: &rng)
        for i in 0..<count {
            // Mostly seconds apart, sometimes a minute or so, sometimes hours.
            switch Int.random(in: 0..<10, using: &rng) {
            case 0..<5: clock += Double.random(in: 0...45, using: &rng)
            case 5..<8: clock += Double.random(in: 50...80, using: &rng)
            default: clock += Double.random(in: 200...50_000, using: &rng)
            }
            let kind: ItemKind
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<70: kind = .photo
            case 70..<80: kind = .livePhoto
            case 80..<88: kind = .screenshot
            case 88..<94: kind = .video
            default: kind = .screenRecording
            }
            let still = kind == .photo || kind == .livePhoto
            let dated = chance(97, &rng)
            let favourite = still && chance(8, &rng)
            let edited = still && chance(8, &rng)
            let portrait = still && chance(5, &rng)
            let longExposure = still && chance(3, &rng)
            let burst = still && chance(12, &rng) ? "B\(Int.random(in: 0..<4, using: &rng))" : nil
            let album = still && chance(10, &rng)
            library.append(
                AssetMetadata(
                    assetID: "a\(i)", kind: kind,
                    captureDate: dated ? Date(timeIntervalSince1970: t0 + clock) : nil,
                    modificationDate: Date(timeIntervalSince1970: t0),
                    pixelWidth: 4032, pixelHeight: 3024, duration: kind.isVideo ? 10 : nil,
                    isFavorite: favourite, hasAdjustments: edited, isPortrait: portrait,
                    isLongExposure: longExposure, burstID: burst, albumNames: album ? ["Trip"] : []))
        }
        guard withStore else { return World(library: library, stored: []) }

        var stored: [StoredItemSummary] = []
        let skips: [VisionWork] = [[], .featurePrint, .faceQuality, .all]
        for m in library {
            guard chance(65, &rng) else { continue }
            var metadata = m
            if chance(12, &rng) {
                // The library changed under it without a new modification date.
                if chance(50, &rng) {
                    metadata.burstID = m.burstID == nil ? "B9" : nil
                } else {
                    metadata.captureDate = m.captureDate.map {
                        $0.addingTimeInterval(Double.random(in: -90...90, using: &rng))
                    }
                }
            }
            if chance(8, &rng) {
                metadata.modificationDate = Date(timeIntervalSince1970: t0 - 100)  // edited since
            }
            let source: AnalysisSource
            if m.kind == .screenshot || m.kind.isVideo {
                source = .metadataOnly
            } else {
                switch Int.random(in: 0..<100, using: &rng) {
                case 0..<72: source = .localPreview
                case 72..<78: source = .cloudPreview
                case 78..<90: source = .notScanned
                default: source = .metadataOnly
                }
            }
            let analyzed = source.hasAnalysis
            stored.append(
                StoredItemSummary(
                    metadata: metadata, analysisSource: source,
                    scanAttempts: source == .notScanned ? Int.random(in: 0...7, using: &rng) : 0,
                    skippedVision: analyzed ? skips[Int.random(in: 0..<4, using: &rng)] : [],
                    sharpness: analyzed ? Double.random(in: 0.3...0.99, using: &rng) : nil))
        }
        for g in 0..<Int.random(in: 0...3, using: &rng) {
            stored.append(
                StoredItemSummary(
                    metadata: AssetMetadata(
                        assetID: "gone\(g)", kind: .photo, pixelWidth: 10, pixelHeight: 10),
                    analysisSource: .localPreview))
        }
        return World(library: library, stored: stored)
    }

    // MARK: The oracle

    static func isPhoto(_ m: AssetMetadata) -> Bool { m.kind == .photo || m.kind == .livePhoto }
    static func needsNoAnalysis(_ m: AssetMetadata) -> Bool { m.kind == .screenshot || m.kind.isVideo }

    /// What the library demands of Vision for a photo: every pair compared, no binary search.
    static func demand(_ m: AssetMetadata, in library: [AssetMetadata]) -> VisionWork {
        guard isPhoto(m) else { return [] }
        if let date = m.captureDate {
            for other in library where other.assetID != m.assetID && isPhoto(other) {
                guard let otherDate = other.captureDate else { continue }
                let (earlier, later) = date <= otherDate ? (date, otherDate) : (otherDate, date)
                if later.timeIntervalSince(earlier) <= SimilarThresholds.window { return .all }
            }
        }
        return m.burstID != nil ? .faceQuality : []
    }

    static func wanted(_ m: AssetMetadata, _ s: StoredItemSummary, in library: [AssetMetadata])
        -> VisionWork
    {
        var work = demand(m, in: library)
        if let sharpness = s.sharpness, UnimportantDetector.isCandidate(m, sharpness: sharpness) {
            work.insert(.faceQuality)
        }
        return work
    }

    /// Stored, unchanged, analyzed photos that skipped what the library now wants (the deep tier's work).
    static func owed(_ w: World) -> [String: VisionWork] {
        let storedByID = Dictionary(w.stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: VisionWork] = [:]
        for m in w.library {
            guard let s = storedByID[m.assetID], s.metadata.modificationDate == m.modificationDate,
                s.analysisSource.hasAnalysis
            else { continue }
            let want = wanted(m, s, in: w.library)
            if !s.skippedVision.isDisjoint(with: want) { result[m.assetID] = want }
        }
        return result
    }

    /// The old repair rule of spec 010 (`.all`): the same, by the library's demand alone.
    static func repairsOfOnePass(_ w: World) -> Set<String> {
        let storedByID = Dictionary(w.stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var result: Set<String> = []
        for m in w.library {
            guard let s = storedByID[m.assetID], s.metadata.modificationDate == m.modificationDate,
                s.analysisSource.hasAnalysis
            else { continue }
            if !s.skippedVision.isDisjoint(with: demand(m, in: w.library)) { result.insert(m.assetID) }
        }
        return result
    }

    /// New or modified, retried, or stored from metadata alone before it was opened.
    static func base(_ w: World, kind: ScanKind) -> Set<String> {
        let storedByID = Dictionary(w.stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var result: Set<String> = []
        for m in w.library {
            guard let s = storedByID[m.assetID], s.metadata.modificationDate == m.modificationDate
            else {
                result.insert(m.assetID)
                continue
            }
            if kind == .full, s.analysisSource == .notScanned,
                s.scanAttempts < ScanRetryPolicy.default.crossScanAttempts
            {
                result.insert(m.assetID)
            } else if s.analysisSource == .metadataOnly, !needsNoAnalysis(m) {
                result.insert(m.assetID)
            }
        }
        return result
    }

    static func near(_ date: Date?, _ triggers: [Date]) -> Bool {
        guard let date else { return false }
        return triggers.contains { abs($0.timeIntervalSince(date)) <= SimilarThresholds.window }
    }

    /// Stored photos that changed under their own modification date: what a tiered quick check treats as
    /// a change in its own right, and a neighbour of one.
    static func chosenByAQuickCheck(
        _ w: World, owed: [String: VisionWork], base: Set<String>, refreshed: Set<String>
    ) -> Set<String> {
        let storedByID = Dictionary(w.stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let libraryByID = Dictionary(w.library.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: Set<String> = []
        for id in owed.keys where storedByID[id]?.metadata != libraryByID[id] { changed.insert(id) }
        let moved = base.union(refreshed).union(changed)
        var triggers: [Date] = []
        for m in w.library where moved.contains(m.assetID) && isPhoto(m) {
            if let date = m.captureDate { triggers.append(date) }
        }
        var chosen: Set<String> = []
        for id in owed.keys {
            if changed.contains(id) || near(libraryByID[id]?.captureDate, triggers) { chosen.insert(id) }
        }
        return chosen
    }

    // MARK: Properties of every plan

    func check(_ w: World, scope: PlanScope, kind: ScanKind, _ label: String) {
        let plan = ScanPlanner.plan(
            library: w.library, stored: w.stored, kind: kind, policy: .default, deferVision: true,
            scope: scope)
        let libraryIDs = Set(w.library.map(\.assetID))
        let storedByID = Dictionary(w.stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let ids = plan.toAnalyze.map(\.assetID)

        // A plan is items of the library, each once, newest first.
        #expect(Set(ids).count == ids.count, "\(label): an item is planned twice")
        #expect(Set(ids).isSubset(of: libraryIDs), "\(label): an item that is not in the library")
        let dates = plan.toAnalyze.map { $0.captureDate ?? .distantPast }
        #expect(dates == dates.sorted(by: >), "\(label): not newest first")
        #expect(plan.gone == Set(storedByID.keys).subtracting(libraryIDs), "\(label): gone")

        // Quick wins are exactly the items that need no analysis, and they stay in the job.
        #expect(
            Set(plan.quickWins.map(\.assetID))
                == Set(plan.toAnalyze.filter(Self.needsNoAnalysis).map(\.assetID)),
            "\(label): quick wins")

        // What is repaired is stored, analyzed, and in the plan; and nothing is refreshed and analyzed.
        let repairIDs = Set(plan.repairs.map(\.assetID))
        #expect(repairIDs.isSubset(of: Set(ids)), "\(label): a repair outside the plan")
        #expect(
            repairIDs.allSatisfy { storedByID[$0]?.analysisSource.hasAnalysis == true },
            "\(label): a repair that is not stored and analyzed")
        let refreshed = Set(plan.refreshed.map(\.assetID))
        #expect(refreshed.isDisjoint(with: Set(ids)), "\(label): refreshed and analyzed")
        let expectedRefreshed = Set(
            w.library.filter {
                guard let s = storedByID[$0.assetID] else { return false }
                return s.metadata.modificationDate == $0.modificationDate && s.metadata != $0
            }.map(\.assetID)
        ).subtracting(ids)
        #expect(refreshed == expectedRefreshed, "\(label): what is refreshed")

        // Which owed photos this scope analyzes, by the plain definition.
        let owed = Self.owed(w)
        let base = Self.base(w, kind: kind)
        let expectedRepairs: Set<String>
        switch scope {
        case .all: expectedRepairs = Self.repairsOfOnePass(w)
        case .photos: expectedRepairs = []
        case .deep: expectedRepairs = Set(owed.keys)
        case .changes:
            expectedRepairs = Self.chosenByAQuickCheck(
                w, owed: owed, base: base.subtracting(Set(owed.keys)), refreshed: expectedRefreshed)
        }
        // Owed photos are never in the base set (they are unchanged and analyzed), so the plan is the
        // base set and the repairs.
        #expect(repairIDs == expectedRepairs, "\(label): repairs")
        #expect(Set(ids) == base.union(expectedRepairs), "\(label): what is analyzed")

        // What is asked of Vision: nothing at all in a photo check, else what the library or a stored
        // photo wants less what is already there, and only for photos that are analyzed at all.
        var expectedSkips: [String: VisionWork] = [:]
        for m in plan.toAnalyze where !Self.needsNoAnalysis(m) {
            let skipped: VisionWork
            if scope == .photos {
                skipped = .all
            } else if scope != .all, let want = owed[m.assetID], repairIDs.contains(m.assetID) {
                skipped = VisionWork.all.subtracting(want)
            } else {
                skipped = VisionWork.all.subtracting(Self.demand(m, in: w.library))
            }
            if !skipped.isEmpty { expectedSkips[m.assetID] = skipped }
        }
        #expect(plan.skipVision == expectedSkips, "\(label): what is skipped")

        // Burst frames listed before any photo is opened, and what the photo check leaves owed.
        let listed = Set(plan.listedEarly.map(\.assetID))
        var burstFrames: [String: Int] = [:]
        for m in w.library where m.kind.isStillImage {
            if let burst = m.burstID { burstFrames[burst, default: 0] += 1 }
        }
        var expectedListed: Set<String> = []
        if scope == .photos {
            for m in w.library where !Self.needsNoAnalysis(m) && storedByID[m.assetID] == nil {
                guard let burst = m.burstID else { continue }
                if (burstFrames[burst] ?? 0) >= BurstThresholds.minimumFrames {
                    expectedListed.insert(m.assetID)
                }
            }
        }
        #expect(listed == expectedListed, "\(label): listed early")
        #expect(listed.isSubset(of: Set(ids)), "\(label): listed early but not planned")

        let expectedDeepOwed: Set<String>
        switch scope {
        case .all, .deep:
            expectedDeepOwed = []
        case .photos:
            // What is already owed, and every photo about to be stored without work the library wants.
            var left = Set(owed.keys)
            for m in plan.toAnalyze where !Self.needsNoAnalysis(m) {
                if !Self.demand(m, in: w.library).isEmpty { left.insert(m.assetID) }
            }
            expectedDeepOwed = left
        case .changes:
            expectedDeepOwed = Set(owed.keys).subtracting(expectedRepairs)
        }
        #expect(plan.deepOwed == expectedDeepOwed, "\(label): what is left owed")
    }

    @Test func everyScopeAndKindPlansWhatTheDefinitionSaysOnRandomStores() {
        for seed in Self.seeds {
            let w = Self.world(seed: seed, stored: true)
            for scope in [PlanScope.all, .changes, .photos, .deep] {
                for kind in [ScanKind.full, .quickCheck] {
                    check(w, scope: scope, kind: kind, "seed \(seed), \(scope), \(kind)")
                }
            }
        }
    }

    @Test func theDefaultScopeIsTheOnePassPlan() {
        for seed in Self.seeds {
            let w = Self.world(seed: seed, stored: true)
            let plain = ScanPlanner.plan(
                library: w.library, stored: w.stored, kind: .full, policy: .default)
            let all = ScanPlanner.plan(
                library: w.library, stored: w.stored, kind: .full, policy: .default,
                scope: .all)
            #expect(plain.toAnalyze == all.toAnalyze, "seed \(seed)")
            #expect(plain.repairs == all.repairs && plain.refreshed == all.refreshed, "seed \(seed)")
            #expect(plain.skipVision == all.skipVision && plain.gone == all.gone, "seed \(seed)")
        }
    }

    // MARK: A tiered scan ends where a one-pass scan ends

    /// Sharpness is the analysis's own result, which the plan cannot know: a fixed function of the id,
    /// so both scans see the same one.
    static func sharpness(_ id: String) -> Double {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return 0.3 + 0.69 * Double(hash % 1_000) / 1_000
    }

    /// What `DefaultAnalyzer` records as skipped, given what it was asked for.
    static func skipped(_ m: AssetMetadata, asked: VisionWork, exact: Bool) -> VisionWork {
        var done = asked
        if !exact, UnimportantDetector.isCandidate(m, sharpness: sharpness(m.assetID)) {
            done.insert(.faceQuality)
        }
        return VisionWork.all.subtracting(done)
    }

    @Test func aTieredPlanEndsWithTheSkipRecordsOfAOnePassPlan() {
        for seed in Self.seeds {
            let library = Self.world(seed: seed, stored: false).library

            // One pass: every photo asked for what the library demands.
            let onePass = ScanPlanner.plan(library: library, stored: [], kind: .full, policy: .default)
            var expected: [String: VisionWork] = [:]
            for m in onePass.toAnalyze where !Self.needsNoAnalysis(m) {
                let asked = VisionWork.all.subtracting(onePass.skipVision[m.assetID] ?? [])
                expected[m.assetID] = Self.skipped(m, asked: asked, exact: false)
            }

            // Tiers: the photo check asks for nothing, then the deep check for what is owed.
            let photos = ScanPlanner.plan(
                library: library, stored: [], kind: .full, policy: .default, scope: .photos)
            var stored: [String: StoredItemSummary] = [:]
            for m in photos.toAnalyze {
                if Self.needsNoAnalysis(m) {
                    stored[m.assetID] = StoredItemSummary(metadata: m, analysisSource: .metadataOnly)
                    continue
                }
                let asked = VisionWork.all.subtracting(photos.skipVision[m.assetID] ?? [])
                #expect(asked.isEmpty, "seed \(seed): the photo check asked \(asked) of \(m.assetID)")
                stored[m.assetID] = StoredItemSummary(
                    metadata: m, analysisSource: .localPreview,
                    skippedVision: Self.skipped(m, asked: asked, exact: true),
                    sharpness: Self.sharpness(m.assetID))
            }
            let deep = ScanPlanner.plan(
                library: library, stored: Array(stored.values), kind: .quickCheck, policy: .default,
                scope: .deep)
            #expect(
                Set(deep.toAnalyze.map(\.assetID)).isSubset(of: Set(stored.keys)),
                "seed \(seed): the deep check plans a photo that is not in the library")
            for m in deep.toAnalyze where !Self.needsNoAnalysis(m) {
                let asked = VisionWork.all.subtracting(deep.skipVision[m.assetID] ?? [])
                stored[m.assetID] = StoredItemSummary(
                    metadata: m, analysisSource: .localPreview,
                    skippedVision: Self.skipped(m, asked: asked, exact: false),
                    sharpness: Self.sharpness(m.assetID))
            }

            var tiered: [String: VisionWork] = [:]
            for (id, s) in stored where s.analysisSource.hasAnalysis { tiered[id] = s.skippedVision }
            #expect(tiered == expected, "seed \(seed): the two scans left different skip records")

            // Nothing is owed any more: the deep check is a fixed point.
            let again = ScanPlanner.plan(
                library: library, stored: Array(stored.values), kind: .quickCheck, policy: .default,
                scope: .deep)
            #expect(again.toAnalyze.isEmpty, "seed \(seed): the deep check owes \(again.toAnalyze.count)")
        }
    }
}
