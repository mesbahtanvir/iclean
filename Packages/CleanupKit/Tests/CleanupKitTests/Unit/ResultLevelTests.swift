import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Spec 011: levels for Similar Shots, and Unimportant photos.
@Suite struct ResultLevelTests {
    // MARK: A pair's strength

    /// A pair of photos with a chosen miniature correlation: identical miniatures correlate at 1, unrelated
    /// ones near 0.
    func pair(related: Bool) -> (LibraryItem, LibraryItem) {
        var rng = SeededRandom(seed: 3)
        let a = Data((0..<1_024).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        let b = related ? a : Data((0..<1_024).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        return (
            Make.item(Make.meta("a", date: date), thumbprint: a),
            Make.item(Make.meta("b", date: date.addingTimeInterval(2)), thumbprint: b)
        )
    }

    @Test func aPairsStrengthFollowsTheRulesOfTheSpec() {
        let detector = SimilarShotsDetector()
        let (a1, b1) = pair(related: true)
        let (a0, b0) = pair(related: false)
        func level(_ x: LibraryItem, _ y: LibraryItem, _ fp: Double) -> ResultLevel? {
            detector.pairLevel(x, y, featurePrintDistance: fp, prints: nil)
        }
        // Miniatures that agree completely.
        #expect(level(a1, b1, 0.03) == .tight)
        #expect(level(a1, b1, 0.09) == .medium)
        #expect(level(a1, b1, 0.14) == .medium)
        #expect(level(a1, b1, 0.20) == .wide)
        #expect(level(a1, b1, 0.30) == nil)
        // Miniatures that do not: the feature print alone decides, and only up to today's limit.
        #expect(level(a0, b0, 0.03) == .medium)
        #expect(level(a0, b0, 0.09) == .medium)
        #expect(level(a0, b0, 0.14) == nil)
        #expect(level(a0, b0, 0.20) == nil)
        // No feature print (Vision unavailable): the miniatures decide.
        #expect(level(a1, b1, .infinity) == .tight)
        #expect(level(a0, b0, .infinity) == nil)
    }

    func noise(_ count: Int, _ rng: inout SeededRandom) -> [UInt8] {
        var out: [UInt8] = []
        for _ in 0..<count { out.append(UInt8(truncatingIfNeeded: rng.next())) }
        return out
    }

    /// `base` with a share of its bytes replaced by noise, so the correlation with it falls as `share` rises.
    func blended(_ base: [UInt8], share: Double, _ rng: inout SeededRandom) -> Data {
        var out = base
        for k in out.indices where rng.unit() < share {
            out[k] = UInt8(truncatingIfNeeded: rng.next())
        }
        return Data(out)
    }

    @Test func theMediumLevelIsExactlyTheRuleThatExistedBefore() {
        let detector = SimilarShotsDetector()
        var rng = SeededRandom(seed: 11)
        var checked = 0
        for k in 0..<400 {
            let base = noise(1_024, &rng)
            let thumbA = Data(base)
            let thumbB = blended(base, share: rng.unit(), &rng)
            let burst: String? = k % 11 == 0 ? "B" : nil
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            let a = Make.item(Make.meta("a\(k)", date: date, burst: burst), thumbprint: thumbA)
            let b = Make.item(Make.meta("b\(k)", date: date, burst: burst), thumbprint: thumbB)
            for fp in [0.0, 0.03, 0.06, 0.09, 0.11, 0.14, 0.16, 0.21, 0.4, .infinity] {
                let oldRule = detector.isSameMoment(a, b, featurePrintDistance: fp)
                let level = detector.pairLevel(a, b, featurePrintDistance: fp, prints: nil)
                let atMedium = level.map { $0 <= .medium } ?? false
                #expect(oldRule == atMedium, "k \(k) fp \(fp) level \(String(describing: level))")
                checked += 1
            }
        }
        #expect(checked == 4_000)
    }

    // MARK: A library with real prints

    /// Shots of scenes: a photo, an identical copy, the same scene with a changed subject, shifted,
    /// blurred, three seconds apart, and each scene two minutes after the last. With real feature prints
    /// and miniatures.
    func library(scenes: Int) async -> [LibraryItem] {
        var items: [LibraryItem] = []
        var clock = 1_600_000_000.0
        func add(_ id: String, _ image: CGImage, at t: Double) async {
            let print = (try? await FeaturePrint.compute(image)) ?? Data()
            items.append(
                Make.item(
                    Make.meta(id, date: Date(timeIntervalSince1970: t)), dHash: dHash(image),
                    thumbprint: Thumbprint.compute(image), print: print, sharpness: 0.8))
        }
        for s in 0..<scenes {
            clock += 120
            let base = TestImages.scene(seed: UInt64(s + 1), width: 96, height: 72)
            await add("s\(s)a", base, at: clock)
            await add("s\(s)b", base, at: clock + 3)
            await add(
                "s\(s)c", TestImages.withSubject(base, seed: UInt64(s + 50), step: 1), at: clock + 6
            )
            await add("s\(s)d", TestImages.shifted(base, dx: 6, dy: 3), at: clock + 9)
            await add("s\(s)e", TestImages.blurred(base, factor: 3), at: clock + 12)
        }
        return items
    }

    func ids(_ groups: [ResultGroup]) -> Set<String> { Set(groups.flatMap(\.members)) }

    /// Frames of one scene shifted by different amounts: similar shots, but not copies of one photo.
    func shiftedFrames(scenes: Int) async -> [LibraryItem] {
        var items: [LibraryItem] = []
        var clock = 1_600_000_000.0
        for s in 0..<scenes {
            clock += 120
            let base = TestImages.scene(seed: UInt64(s + 100), width: 96, height: 72)
            for k in 0..<3 {
                let image = TestImages.shifted(base, dx: 6 * (k + 1), dy: 3 * (k + 1))
                let print = (try? await FeaturePrint.compute(image)) ?? Data()
                items.append(
                    Make.item(
                        Make.meta(
                            "f\(s)_\(k)", date: Date(timeIntervalSince1970: clock + Double(k) * 3)),
                        dHash: dHash(image), thumbprint: Thumbprint.compute(image), print: print,
                        sharpness: 0.8))
            }
        }
        return items
    }

    @Test func levelsNestAndTheSummariesCountWhatEachLevelLists() async {
        let items = await library(scenes: 30)
        var groupsAt: [ResultLevel: [ResultGroup]] = [:]
        var summaryAt: [ResultLevel: LevelSummary] = [:]
        for level in ResultLevel.allCases {
            let detection = SimilarShotsDetector(levels: ResultLevels([.similar: level]))
                .detectLevelled(items: items, all: items)
            #expect(detection.level == level)
            groupsAt[level] = detection.groups
            for s in detection.levels { summaryAt[s.level] = s }
            // The summary of the chosen level is what the groups are.
            let chosen = detection.levels.first { $0.level == level }
            #expect(chosen?.groups == detection.groups.count)
            #expect(chosen?.photos == detection.groups.map(\.members.count).reduce(0, +))
        }
        // The same three summaries come out whichever level is chosen.
        for level in ResultLevel.allCases {
            let again = SimilarShotsDetector(levels: ResultLevels([.similar: level]))
                .detectLevelled(items: items, all: items).levels
            #expect(again == ResultLevel.allCases.compactMap { summaryAt[$0] })
        }
        let tight = ids(groupsAt[.tight]!)
        let medium = ids(groupsAt[.medium]!)
        let wide = ids(groupsAt[.wide]!)
        #expect(!tight.isEmpty, "identical copies are almost identical")
        #expect(tight.isSubset(of: medium))
        #expect(medium.isSubset(of: wide))
        // Every group lies inside one group of the next level.
        for (inner, outer) in [(ResultLevel.tight, ResultLevel.medium), (.medium, .wide)] {
            for g in groupsAt[inner]! {
                let homes = Set(
                    groupsAt[outer]!.filter { !Set($0.members).isDisjoint(with: g.members) }.map(
                        \.id))
                #expect(homes.count == 1, "a \(inner) group is split across \(outer) groups")
            }
        }
        #expect(summaryAt[.tight]!.photos <= summaryAt[.medium]!.photos)
        #expect(summaryAt[.medium]!.photos <= summaryAt[.wide]!.photos)
    }

    @Test func theDefaultLevelGivesTheGroupsTheDetectorAlwaysGave() async {
        let items = await library(scenes: 20)
        let plain = SimilarShotsDetector().detect(items: items)
        let explicit = SimilarShotsDetector(levels: ResultLevels([.similar: .medium])).detect(
            items: items)
        #expect(plain == explicit)
        // And those are the sets of the old loop: every pair that was the same moment, joined.
        let sorted = items.sorted { $0.metadata.captureDate! < $1.metadata.captureDate! }
        var uf = UnionFind(count: sorted.count)
        let cache = FeaturePrintCache()
        let detector = SimilarShotsDetector()
        for i in sorted.indices {
            var j = i + 1
            while j < sorted.count,
                sorted[j].metadata.captureDate!.timeIntervalSince(sorted[i].metadata.captureDate!)
                    <= SimilarThresholds.window
            {
                if detector.isSameMoment(sorted[i], sorted[j], prints: cache) { uf.union(i, j) }
                j += 1
            }
        }
        let oldSets = Set(uf.groups().map { Set($0.map { sorted[$0].assetID }) })
        #expect(Set(plain.map { Set($0.members) }) == oldSets)
    }

    @Test func everyLevelFindsTheSameWithManyThreads() async {
        let items = await library(scenes: 30)
        for level in ResultLevel.allCases {
            let levels = ResultLevels([.similar: level])
            let serial = SimilarShotsDetector(levels: levels).detectLevelled(
                items: items, all: items)
            let parallel = SimilarShotsDetector(
                parallelism: 4, parallelThreshold: 0, levels: levels
            )
            .detectLevelled(items: items, all: items)
            #expect(serial.groups == parallel.groups, "\(level)")
            #expect(serial.levels == parallel.levels, "\(level)")
        }
    }

    // MARK: The builder

    func builder(levels: ResultLevels) -> DefaultResultsBuilder {
        DefaultResultsBuilder(detectors: StandardPipeline.detectors(parallelism: 1, levels: levels))
    }

    @Test func theWideLevelPreselectsNothingAndTheOthersPreselectAsBefore() async {
        let items = await shiftedFrames(scenes: 12)
        let medium = builder(levels: ResultLevels()).buildResults(items: items, keepMarks: [])
        let simMedium = medium.category(.similar)
        #expect(medium.category(.duplicates) == nil, "the frames are shifted, not copies")
        #expect(simMedium?.level == .medium)
        #expect(simMedium?.levels.count == 3)
        #expect(!(simMedium?.removable.isEmpty ?? true))
        let mediumRemovable = Set(simMedium?.removable ?? [])
        #expect(mediumRemovable.isSubset(of: medium.defaultSelection))

        let wide = builder(levels: ResultLevels([.similar: .wide])).buildResults(
            items: items, keepMarks: [])
        let simWide = wide.category(.similar)
        #expect(simWide?.level == .wide)
        let wideRemovable = Set(simWide?.removable ?? [])
        #expect(wideRemovable.isDisjoint(with: wide.defaultSelection))

        let tight = builder(levels: ResultLevels([.similar: .tight])).buildResults(
            items: items, keepMarks: [])
        let tightRemovable = Set(tight.category(.similar)?.removable ?? [])
        #expect(tightRemovable.isSubset(of: tight.defaultSelection))
    }

    @Test func theSelectionAfterReplayingDecisionsFollowsTheLevelToo() async {
        // `ReviewIntent` recomputes the defaults when results are shown; it must agree with the builder.
        let items = await shiftedFrames(scenes: 8)
        for (level, selects) in [(ResultLevel.tight, true), (.medium, true), (.wide, false)] {
            let built = builder(levels: ResultLevels([.similar: level])).buildResults(
                items: items, keepMarks: [])
            guard let similar = built.category(.similar) else { continue }
            let applied = ReviewIntent().apply(to: built, keepMarks: [])
            let removable = Set(similar.removable)
            #expect(!removable.isEmpty)
            #expect(applied.selection.isSuperset(of: removable) == selects, "\(level)")
            #expect(applied.selection == built.defaultSelection, "\(level)")
        }
    }

    @Test func aCategoryStaysWhenAnotherLevelWouldListSomethingButNotAtTheDefault() throws {
        // Two photos that only the wide rule joins: feature prints are unavailable, so the miniatures
        // decide, and their correlation sits between the wide limit and the medium one.
        var rng = SeededRandom(seed: 21)
        let base = noise(1_024, &rng)
        var mixed: Data?
        for step in 1...40 {
            let candidate = blended(base, share: Double(step) / 40, &rng)
            let t = Thumbprint.similarity(Data(base), candidate)
            if t >= SimilarThresholds.wideThumbprintWithoutPrint + 0.02,
                t < SimilarThresholds.thumbprint - 0.02
            {
                mixed = candidate
                break
            }
        }
        let other = try #require(mixed, "a fixture between the wide and the medium rule")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let items = [
            Make.item(Make.meta("a", date: date), thumbprint: Data(base), print: Data([1])),
            Make.item(
                Make.meta("b", date: date.addingTimeInterval(2)), thumbprint: other,
                print: Data([1])),
        ]
        let atDefault = builder(levels: ResultLevels()).buildResults(items: items, keepMarks: [])
        #expect(
            atDefault.category(.similar) == nil,
            "nothing at the default level means no category, as before")
        let atWide = builder(levels: ResultLevels([.similar: .wide])).buildResults(
            items: items, keepMarks: [])
        #expect(atWide.category(.similar)?.groups.count == 1)
        let atTight = builder(levels: ResultLevels([.similar: .tight])).buildResults(
            items: items, keepMarks: [])
        #expect(
            atTight.category(.similar)?.groups.isEmpty == true,
            "stays so the person can step back out")
        #expect(atTight.category(.similar)?.levels.contains { $0.photos > 0 } == true)
    }

    // MARK: Unimportant

    func shaky(
        _ id: String, sharpness: Double = 0.5, face: Double? = nil, aesthetics: Double? = nil,
        at t: Double, favorite: Bool = false, albums: [String] = [], edited: Bool = false,
        portrait: Bool = false, located: Bool? = false, print: Data = Data([1])
    ) -> LibraryItem {
        var meta = Make.meta(
            id, date: Date(timeIntervalSince1970: 1_600_000_000 + t), favorite: favorite,
            edited: edited,
            portrait: portrait, albums: albums)
        meta.hasLocation = located
        return Make.item(
            meta, print: print, sharpness: sharpness, aesthetics: aesthetics, face: face)
    }

    @Test func theScoreAddsWhatTheSpecSaysAndTheLevelsCutItAtSevenFiveThree() {
        func score(_ item: LibraryItem, neighbour: Bool = false) -> Int? {
            UnimportantDetector.score(item, hasNeighbour: neighbour)
        }
        // Badly shaken (3) + alone (2) + no location (1).
        #expect(score(shaky("a", sharpness: 0.50, at: 0)) == 6)
        // Shaky (2) + alone (2) + no location (1).
        #expect(score(shaky("a", sharpness: 0.58, at: 0)) == 5)
        // Soft (1) + alone (2).
        #expect(score(shaky("a", sharpness: 0.66, at: 0, located: nil)) == 3)
        // With a neighbour the alone points go.
        #expect(score(shaky("a", sharpness: 0.50, at: 0), neighbour: true) == 4)
        // A known low aesthetics score adds 2: shaky + alone + no location + aesthetics = 7.
        #expect(score(shaky("a", sharpness: 0.58, aesthetics: -0.2, at: 0)) == 7)
        #expect(score(shaky("a", sharpness: 0.58, aesthetics: 0.3, at: 0)) == 5)
        // Not soft enough: never listed.
        #expect(score(shaky("a", sharpness: 0.75, at: 0)) == nil)
    }

    @Test func nothingProtectedIsEverListed() {
        func score(_ item: LibraryItem) -> Int? {
            UnimportantDetector.score(item, hasNeighbour: false)
        }
        #expect(score(shaky("ok", at: 0)) != nil)
        #expect(score(shaky("face", face: 0.4, at: 0)) == nil)
        #expect(score(shaky("fav", at: 0, favorite: true)) == nil)
        #expect(score(shaky("album", at: 0, albums: ["Trip"])) == nil)
        #expect(score(shaky("edited", at: 0, edited: true)) == nil)
        #expect(score(shaky("portrait", at: 0, portrait: true)) == nil)
        var video = shaky("video", at: 0)
        video.metadata.kind = .video
        #expect(score(video) == nil)
        var shot = shaky("shot", at: 0)
        shot.metadata.kind = .screenshot
        #expect(score(shot) == nil)
    }

    @Test func neighboursAreCountedAmongEverythingExaminedNotJustWhatIsLeft() {
        let lonely = shaky("lonely", sharpness: 0.50, at: 0)
        let taken = shaky("taken", sharpness: 0.9, at: 30)  // an earlier category took this one
        let far = shaky("far", sharpness: 0.50, at: 5_000)
        let detector = UnimportantDetector()
        let withNeighbour = detector.detectLevelled(
            items: [lonely, far], all: [lonely, taken, far])
        let summary = withNeighbour.levels
        // lonely: 3 + 1 (no location) = 4 (a neighbour within 60 s); far: 3 + 2 + 1 = 6.
        #expect(summary.first { $0.level == .wide }?.photos == 2)  // both ≥ 3
        #expect(summary.first { $0.level == .medium }?.photos == 1)  // only `far` ≥ 5
        #expect(summary.first { $0.level == .tight }?.photos == 0)
    }

    @Test func withoutVisionNothingIsListedBecauseNoFaceMeansNothing() {
        let items = [
            shaky("a", sharpness: 0.5, at: 0, print: Data()),
            shaky("b", sharpness: 0.5, at: 5_000, print: Data()),
        ]
        #expect(
            UnimportantDetector().detectLevelled(items: items, all: items).levels.allSatisfy {
                $0.photos == 0
            })
        // One photo with a print anywhere in the library shows Vision worked.
        let withOne = items + [shaky("c", sharpness: 0.9, at: 90_000)]
        #expect(
            UnimportantDetector().detectLevelled(items: withOne, all: withOne).levels
                .first { $0.level == .wide }?.photos == 2)
    }

    @Test func photosAreListedMostLikelyFirstAndTheChosenLevelCutsTheList() {
        let items = [
            shaky("soft", sharpness: 0.66, at: 10_000, located: nil),  // 1 + 2 = 3
            shaky("worst", sharpness: 0.50, aesthetics: -0.3, at: 20_000),  // 3 + 2 + 1 + 2 = 8
            shaky("mid", sharpness: 0.58, at: 30_000),  // 2 + 2 + 1 = 5
        ]
        func ids(_ level: ResultLevel) -> [String] {
            UnimportantDetector(levels: ResultLevels([.unimportant: level]))
                .detectLevelled(items: items, all: items).groups.flatMap(\.members)
        }
        #expect(ids(.tight) == ["worst"])
        #expect(ids(.medium) == ["worst", "mid"])
        #expect(ids(.wide) == ["worst", "mid", "soft"])
    }

    @Test func anEarlierCategoryKeepsItsPhotosAndNothingInUnimportantIsPreselected() {
        // Soft, alone, and below the blur threshold with no aesthetics score: Blurry takes it first.
        let blurry = shaky("blurry", sharpness: 0.40, at: 10_000)
        let unimportant = shaky("unimportant", sharpness: 0.50, aesthetics: 0.4, at: 20_000)
        let anchor = shaky("anchor", sharpness: 0.9, at: 30_000)  // gives Vision a print to show it worked
        let results = builder(levels: ResultLevels()).buildResults(
            items: [blurry, unimportant, anchor], keepMarks: [])
        #expect(results.category(.blurry)?.allMembers == ["blurry"])
        let listed = results.category(.unimportant)
        #expect(listed?.allMembers == ["unimportant"])
        #expect(listed?.level == .medium)
        #expect(!results.defaultSelection.contains("unimportant"))
        #expect(CleanupCategory.unimportant.preselects(at: .tight) == false)
        // A favourite is protected by the builder too.
        var fav = unimportant
        fav.metadata.isFavorite = true
        #expect(
            builder(levels: ResultLevels()).buildResults(items: [fav, anchor], keepMarks: [])
                .category(.unimportant) == nil)
        // And so is a keep mark.
        #expect(
            builder(levels: ResultLevels()).buildResults(
                items: [unimportant, anchor], keepMarks: ["unimportant"]
            )
            .category(.unimportant) == nil)
    }

    // MARK: Saved results

    @Test func aSnapshotKeepsTheLevelAndAnOldOneStillOpens() throws {
        let items = [
            shaky("a", sharpness: 0.5, aesthetics: 0.4, at: 0),
            shaky("b", sharpness: 0.5, aesthetics: 0.4, at: 5_000),
            shaky("c", sharpness: 0.9, at: 90_000),
        ]
        let results = builder(levels: ResultLevels()).buildResults(items: items, keepMarks: [])
        let key = BuilderKey(detectors: [.unimportant], features: .free, access: .full)
        let sealed = try StateCodec.seal(
            ResultsSnapshot(results: results, builderKey: key, itemCount: 3, keepMarkCount: 0))
        let restored = try StateCodec.open(sealed, as: ResultsSnapshot.self).results()
        #expect(restored.category(.unimportant)?.level == results.category(.unimportant)?.level)
        #expect(restored.category(.unimportant)?.levels == results.category(.unimportant)?.levels)

        // A category saved before spec 011 has neither field.
        let old = #"{"category":"similar","groups":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ResultsSnapshot.Category.self, from: old)
        #expect(decoded.level == nil && decoded.levels == nil)
    }

    @Test func theLevelsAreAPartOfTheBuilderKey() {
        let a = BuilderKey(
            detectors: [.similar], features: .free, access: .full, levels: ResultLevels())
        let b = BuilderKey(
            detectors: [.similar], features: .free, access: .full,
            levels: ResultLevels([.similar: .wide]))
        let c = BuilderKey(detectors: [.similar], features: .free, access: .full)
        #expect(a != b)
        #expect(a == c, "no levels means the defaults")
        #expect(ResultLevels().key == "similar=2,unimportant=2")
    }
}
