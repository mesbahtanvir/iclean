import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Spec 017: a scan in tiers (library facts, then a photo check with no Vision work, then a deep check
/// with the Vision work that is owed) lists the cheap categories first and ends where a one-pass scan
/// ends.
@Suite struct TieredScanTests {
    let fast = ScanRetryPolicy(
        chunkSize: 16, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .seconds(20), crashBudget: 5, crossScanAttempts: 6)
    let t0 = 1_600_000_000.0
    let image = TestImages.scene(seed: 3, width: 64, height: 48)

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: t0 + seconds) }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> [ScanProgress] {
        var all: [ScanProgress] = []
        for await p in stream { all.append(p) }
        return all
    }

    /// Does only the Vision work it is asked for, adds the Unimportant face pass unless told not to
    /// (like `DefaultAnalyzer`), and records every request in order. Sharpness comes from a table, so a
    /// test can make a photo soft.
    final class RequestLog: Analyzer, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String: [VisionWork]] = [:]
        let sharpness: [String: Double]

        init(sharpness: [String: Double] = [:]) { self.sharpness = sharpness }

        func requests(_ id: String) -> [VisionWork] { lock.withLock { asked[id] ?? [] } }

        func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
            try await analyze(image, metadata: metadata, vision: .all)
        }

        func analyze(_ image: CGImage, metadata: AssetMetadata, vision: VisionWork) async throws
            -> Analysis
        {
            lock.withLock { asked[metadata.assetID, default: []].append(vision) }
            let sharp = sharpness[metadata.assetID] ?? 0.9
            var done = vision
            if !vision.contains(.exact), UnimportantDetector.isCandidate(metadata, sharpness: sharp)
            {
                done.insert(.faceQuality)
            }
            return Analysis(
                dHash: UInt64(image.width), featurePrint: Data(), sharpness: sharp,
                skippedVision: VisionWork.all.subtracting(done))
        }
    }

    /// Two neighbours, a sharp photo alone, a soft one alone, a burst of three, a screenshot and a
    /// video. After a photo check six of them are owed Vision work: the pair and the burst (a
    /// neighbour each) and the soft photo (the face pass Unimportant reads).
    func library() -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("pairA", date: at(0)), preview: .local(image))
        lib.add(Make.meta("pairB", date: at(20)), preview: .local(image))
        lib.add(Make.meta("soloSharp", date: at(10_000)), preview: .local(image))
        lib.add(Make.meta("soloSoft", date: at(20_000)), preview: .local(image))
        for k in 0..<3 {
            lib.add(
                Make.meta("burst\(k)", date: at(30_000 + Double(k)), burst: "B"),
                preview: .local(image))
        }
        lib.add(Make.meta("shot", kind: .screenshot, date: at(40_000)), preview: .local(image))
        lib.add(
            Make.meta("clip", kind: .video, date: at(41_000), duration: 12), preview: .local(image))
        return lib
    }

    static let softOnes = ["soloSoft": 0.5]
    static let owedAfterThePhotoCheck: Set<String> = [
        "pairA", "pairB", "soloSoft", "burst0", "burst1", "burst2",
    ]

    func tieredScanner(
        _ lib: FakePhotoLibrary, store: SwiftDataStore, log: RequestLog,
        wait: DeepWait? = nil
    ) -> ScanPipeline {
        ScanPipeline(
            library: lib, store: store, analyzer: log, profile: .phone, policy: fast,
            tiered: true, deepWait: { wait })
    }

    // MARK: The model

    @Test func everyCategoryHasOneTierAndTheTiersPartitionThem() {
        #expect(CleanupCategory.bursts.tier == .instant)
        #expect(CleanupCategory.screenshots.tier == .instant)
        #expect(CleanupCategory.screenRecordings.tier == .instant)
        #expect(CleanupCategory.largeVideos.tier == .instant)
        #expect(CleanupCategory.livePhotos.tier == .instant)
        #expect(CleanupCategory.duplicates.tier == .photos)
        #expect(CleanupCategory.blurry.tier == .photos)
        #expect(CleanupCategory.dark.tier == .photos)
        #expect(CleanupCategory.similar.tier == .deep)
        #expect(CleanupCategory.unimportant.tier == .deep)
        let listed = ScanTier.allCases.flatMap(\.categories)
        #expect(listed.count == CleanupCategory.allCases.count)
        #expect(Set(listed) == Set(CleanupCategory.allCases))
        #expect(ScanTier.instant < .photos && ScanTier.photos < .deep)
    }

    @Test func aDetectorThatNeedsNoAnalysisIsAnInstantTierCategory() {
        // The tier table and the detectors say the same thing: a category that reads only metadata is
        // listed before any photo is opened, and one that reads the analysis is not.
        for detector in StandardPipeline.detectors() {
            let category = detector.category
            #expect(
                detector.needsAnalysis == (category.tier != .instant), "\(category.rawValue)")
        }
    }

    // MARK: The photo check plan

    @Test func aPhotoCheckPlanAsksForNoVisionAndListsBurstFramesEarly() {
        let library = [
            Make.meta("alone", date: at(0)),
            Make.meta("n1", date: at(5_000)), Make.meta("n2", date: at(5_020)),
            Make.meta("b0", date: at(9_000), burst: "B"),
            Make.meta("b1", date: at(9_001), burst: "B"),
            // A burst of one frame is not a group.
            Make.meta("single", date: at(12_000), burst: "ONE"),
            Make.meta("shot", kind: .screenshot, date: at(13_000)),
            Make.meta("clip", kind: .video, date: at(14_000), duration: 5),
        ]
        let plan = ScanPlanner.plan(
            library: library, stored: [], kind: .full, policy: .default, scope: .photos)
        for id in ["alone", "n1", "n2", "b0", "b1", "single"] {
            #expect(plan.skipVision[id] == .all, "\(id)")
        }
        #expect(plan.skipVision["shot"] == nil && plan.skipVision["clip"] == nil)
        #expect(plan.repairs.isEmpty)
        #expect(Set(plan.listedEarly.map(\.assetID)) == ["b0", "b1"])
        // They stay in the job, so counts and chunks are unchanged.
        #expect(plan.toAnalyze.count == library.count)
        // What the photo check will leave owed: photos a detector can group, not the one alone.
        #expect(plan.deepOwed == ["n1", "n2", "b0", "b1", "single"])

        // A frame that is stored already keeps its analysis until it is analyzed again.
        let stored = [StoredItemSummary(metadata: library[3], analysisSource: .localPreview)]
        let later = ScanPlanner.plan(
            library: library, stored: stored, kind: .full, policy: .default, scope: .photos)
        #expect(Set(later.listedEarly.map(\.assetID)) == ["b1"])

        // Without tiers nothing is listed early and nothing is owed.
        let onePass = ScanPlanner.plan(
            library: library, stored: [], kind: .full, policy: .default)
        #expect(onePass.listedEarly.isEmpty && onePass.deepOwed.isEmpty)
        #expect(onePass.skipVision["n1"] == nil)
    }

    @Test func aStoredMetadataOnlyPhotoIsPlannedAgainButAScreenshotIsNot() {
        let photo = Make.meta("p", date: at(0))
        let shot = Make.meta("s", kind: .screenshot, date: at(10))
        let clip = Make.meta("v", kind: .video, date: at(20), duration: 3)
        let stored = [photo, shot, clip].map {
            StoredItemSummary(metadata: $0, analysisSource: .metadataOnly)
        }
        for scope in [PlanScope.all, .photos, .deep, .changes] {
            let plan = ScanPlanner.plan(
                library: [photo, shot, clip], stored: stored, kind: .quickCheck, policy: .default,
                scope: scope)
            #expect(plan.toAnalyze.map(\.assetID) == ["p"], "\(scope)")
        }
    }

    // MARK: The deep plan

    func summary(
        _ m: AssetMetadata, sharpness: Double, skipped: VisionWork = .all
    ) -> StoredItemSummary {
        StoredItemSummary(
            metadata: m, analysisSource: .localPreview, skippedVision: skipped,
            sharpness: sharpness)
    }

    @Test func theDeepPlanOwesWhatTheLibraryDemandsAndWhatUnimportantReads() {
        let neighbour1 = Make.meta("n1", date: at(0))
        let neighbour2 = Make.meta("n2", date: at(30))
        let sharp = Make.meta("sharp", date: at(10_000))
        let soft = Make.meta("soft", date: at(20_000))
        let softFavourite = Make.meta("softFav", date: at(30_000), favorite: true)
        let softAlbum = Make.meta("softAlbum", date: at(40_000), albums: ["Trip"])
        let lonelyBurst = Make.meta("lonelyBurst", date: at(50_000), burst: "B")
        let library = [neighbour1, neighbour2, sharp, soft, softFavourite, softAlbum, lonelyBurst]
        let stored = [
            summary(neighbour1, sharpness: 0.9), summary(neighbour2, sharpness: 0.9),
            summary(sharp, sharpness: 0.9), summary(soft, sharpness: 0.5),
            summary(softFavourite, sharpness: 0.5), summary(softAlbum, sharpness: 0.5),
            summary(lonelyBurst, sharpness: 0.9),
        ]
        let plan = ScanPlanner.plan(
            library: library, stored: stored, kind: .quickCheck, policy: .default, scope: .deep)
        let owed: Set<String> = ["n1", "n2", "soft", "lonelyBurst"]
        #expect(Set(plan.toAnalyze.map(\.assetID)) == owed)
        #expect(Set(plan.repairs.map(\.assetID)) == owed)
        // Each is asked for exactly what is owed.
        #expect(plan.skipVision["n1"] == nil && plan.skipVision["n2"] == nil)
        #expect(plan.skipVision["soft"] == .featurePrint)
        #expect(plan.skipVision["lonelyBurst"] == .featurePrint)
        // Nothing is owed after it.
        #expect(plan.deepOwed.isEmpty)
    }

    @Test func aPhotoWhoseWorkIsDoneIsNotOwedItAgain() {
        let soft = Make.meta("soft", date: at(0))
        // The face pass ran (so only the print was skipped); the print is not wanted for a lone photo.
        let done = summary(soft, sharpness: 0.5, skipped: .featurePrint)
        let plan = ScanPlanner.plan(
            library: [soft], stored: [done], kind: .quickCheck, policy: .default, scope: .deep)
        #expect(plan.toAnalyze.isEmpty)
        // And a photo whose neighbour left is not owed what it skipped for lack of one.
        let alone = Make.meta("alone", date: at(10_000))
        let plain = ScanPlanner.plan(
            library: [alone], stored: [summary(alone, sharpness: 0.9)], kind: .quickCheck,
            policy: .default, scope: .deep)
        #expect(plain.toAnalyze.isEmpty)
    }

    // MARK: The quick check of a tiered scan

    @Test func aQuickCheckRepairsOnlyWhatIsNearAChange() {
        // A backlog: two pairs far apart, stored without Vision work, and an arrival next to the
        // first pair's second photo only.
        let a1 = Make.meta("a1", date: at(0))
        let a2 = Make.meta("a2", date: at(30))
        let b1 = Make.meta("b1", date: at(50_000))
        let b2 = Make.meta("b2", date: at(50_030))
        let arrival = Make.meta("new", date: at(70))
        let stored = [a1, a2, b1, b2].map { summary($0, sharpness: 0.9) }

        let plan = ScanPlanner.plan(
            library: [a1, a2, b1, b2, arrival], stored: stored, kind: .quickCheck,
            policy: .default, scope: .changes)
        // a2 is 40 s from the arrival; a1 is 70 s from it, and was owed before it came.
        #expect(Set(plan.toAnalyze.map(\.assetID)) == ["new", "a2"])
        #expect(Set(plan.repairs.map(\.assetID)) == ["a2"])
        #expect(plan.deepOwed == ["a1", "b1", "b2"])
        #expect(plan.skipVision["a2"] == nil)

        // Nothing changed: nothing is analyzed, all four are still owed.
        let quiet = ScanPlanner.plan(
            library: [a1, a2, b1, b2], stored: stored, kind: .quickCheck, policy: .default,
            scope: .changes)
        #expect(quiet.toAnalyze.isEmpty && quiet.deepOwed == ["a1", "a2", "b1", "b2"])

        // The one-pass plan repairs all four, which is what a tiered quick check must not do.
        let onePass = ScanPlanner.plan(
            library: [a1, a2, b1, b2], stored: stored, kind: .quickCheck, policy: .default)
        #expect(Set(onePass.repairs.map(\.assetID)) == ["a1", "a2", "b1", "b2"])
    }

    @Test func aPhotoThatChangedItselfIsRepairedWithItsNeighbours() {
        let b1 = Make.meta("b1", date: at(50_000))
        let b2 = Make.meta("b2", date: at(50_030))
        let far = Make.meta("far", date: at(90_000))
        let farMate = Make.meta("farMate", date: at(90_020))
        var burstB1 = b1
        burstB1.burstID = "late"  // the modification date is the same
        let stored = [b1, b2, far, farMate].map { summary($0, sharpness: 0.9) }
        let plan = ScanPlanner.plan(
            library: [burstB1, b2, far, farMate], stored: stored, kind: .quickCheck,
            policy: .default, scope: .changes)
        #expect(Set(plan.repairs.map(\.assetID)) == ["b1", "b2"])
        #expect(plan.deepOwed == ["far", "farMate"])
    }

    @Test func aDateWindowIncludesExactlyAMinute() {
        let window = DateWindow([at(0), at(1_000)])
        #expect(window.hasDate(near: at(60)))
        #expect(!window.hasDate(near: at(60.5)))
        #expect(window.hasDate(near: at(940)))
        #expect(!window.hasDate(near: at(939.5)))
        #expect(window.hasDate(near: at(-60)))
        #expect(!window.hasDate(near: nil))
        #expect(!DateWindow([]).hasDate(near: at(0)))
    }

    // MARK: Progress

    @Test func theTierStatusFollowsTheProgress() {
        func progress(
            _ state: ScanState, tier: ScanTier?, done: Int = 10, of total: Int = 100,
            owed: Int = 0, wait: DeepWait? = nil
        ) -> ScanProgress {
            ScanProgress(
                processed: done, total: total, notScanned: 0, state: state, tier: tier,
                deepRemaining: owed, deepWait: wait)
        }
        // Not a tiered scan, or not started.
        #expect(ScanTierStatus(progress(.running, tier: nil)) == nil)
        #expect(ScanTierStatus(progress(.idle, tier: .photos)) == nil)

        let photos = ScanTierStatus(progress(.running, tier: .photos))
        #expect(photos?.instant == .ready)
        #expect(photos?.photos == .running(done: 10, total: 100))
        #expect(photos?.deep == .waiting)
        #expect(ScanTierStatus(progress(.running, tier: .photos, wait: .lowPowerMode))?.deep
            == .waitingFor(.lowPowerMode))

        let deep = ScanTierStatus(progress(.running, tier: .deep, done: 3, of: 6))
        #expect(deep?.photos == .ready && deep?.deep == .running(done: 3, total: 6))

        // A photo check that ended and left the deep check owed, waiting or not.
        let owed = ScanTierStatus(progress(.completed, tier: .photos, owed: 6))
        #expect(owed?.photos == .ready && owed?.deep == .notRun(owed: 6))
        let waiting = ScanTierStatus(
            progress(.completed, tier: .photos, owed: 6, wait: .lowPowerMode))
        #expect(waiting?.deep == .waitingFor(.lowPowerMode))
        #expect(ScanTierStatus(progress(.completed, tier: .photos, owed: 0))?.deep == .ready)

        // Stopped, in either tier.
        let stoppedDeep = ScanTierStatus(progress(.stopped, tier: .deep, owed: 4))
        #expect(stoppedDeep?.deep == .notRun(owed: 4))
        let stoppedPhotos = ScanTierStatus(progress(.stopped, tier: .photos, done: 40, of: 100))
        #expect(stoppedPhotos?.photos == .notRun(owed: 60))
        #expect(ScanTierStatus(progress(.completed, tier: .deep))?.deep == .ready)
        #expect(ScanTierStatus(progress(.running, tier: .photos))?[.instant] == .ready)
    }

    // MARK: The store

    @Test func aSessionKeepsItsTierAndAnOldOneHasNone() async throws {
        let store = try InMemoryStore.make()
        var job = ScanSession(kind: .full, state: .running, totalItems: 3, tier: .deep)
        try await store.createJob(job, chunks: [])
        #expect(try await store.currentSession()?.tier == .deep)
        job.state = .completed
        try await store.saveSession(job)
        let plain = ScanSession(kind: .full, state: .running, totalItems: 1)
        try await store.createJob(plain, chunks: [])
        #expect(try await store.currentSession()?.tier == nil)
        #expect(try await store.sessions().map(\.tier) == [nil, .deep])
    }

    @Test func aSummaryCarriesTheStoredSharpness() async throws {
        let store = try InMemoryStore.make()
        try await store.upsert([
            Make.item(Make.meta("a", date: at(0)), sharpness: 0.42),
            LibraryItem(
                metadata: Make.meta("s", kind: .screenshot, date: at(1)),
                analysisSource: .metadataOnly, analysis: nil),
        ])
        let summaries = Dictionary(
            uniqueKeysWithValues: try await store.itemSummaries().map { ($0.assetID, $0) })
        #expect(summaries["a"]?.sharpness == 0.42)
        #expect(summaries["s"]?.sharpness == nil)
    }

    // MARK: The pipeline

    @Test func aTieredScanRunsThePhotoCheckThenTheDeepCheck() async throws {
        let lib = library()
        let log = RequestLog(sharpness: Self.softOnes)
        let store = try InMemoryStore.make()
        let scanner = tieredScanner(lib, store: store, log: log)
        let events = await drain(await scanner.startFullScan())

        // The photo check asked for no Vision work and forbade any other.
        for id in ["pairA", "pairB", "soloSharp", "soloSoft", "burst0", "burst1", "burst2"] {
            #expect(log.requests(id).first == .exact, "\(id)")
        }
        // The deep check asked for exactly what was owed, and for nothing from the photos not owed.
        #expect(log.requests("soloSharp") == [.exact])
        #expect(log.requests("pairA") == [.exact, .all])
        #expect(log.requests("pairB") == [.exact, .all])
        #expect(log.requests("burst1") == [.exact, .all])
        #expect(log.requests("soloSoft") == [.exact, .faceQuality])
        // Screenshots and videos are listed from metadata and never reach the analyzer.
        #expect(log.requests("shot").isEmpty && log.requests("clip").isEmpty)

        // One stream, two jobs, one ending: the first job's end is not an event.
        let last = try #require(events.last)
        #expect(last.state == .completed && last.tier == .deep)
        #expect(last.total == 6 && last.processed == 6 && last.deepRemaining == 0)
        #expect(events.dropLast().allSatisfy { $0.state != .completed })
        let tiers = events.compactMap(\.tier)
        #expect(tiers == tiers.sorted() && tiers.first == .photos && tiers.last == .deep)
        #expect(events.map(\.publishedRevision) == events.map(\.publishedRevision).sorted())

        // Two completed jobs, newest first.
        let sessions = try await store.sessions()
        #expect(sessions.map(\.tier) == [.deep, .photos])
        #expect(sessions.allSatisfy { $0.state == .completed && $0.kind == .full })
        // The screenshot and the video stay in the job, as in every job since 008.
        #expect(sessions[1].totalItems == 9 && sessions[1].processedItems == 9)

        // What is stored equals what a one-pass scan stores for the work a detector reads.
        let items = Dictionary(
            uniqueKeysWithValues: try await store.items().map { ($0.assetID, $0) })
        #expect(items["pairA"]?.analysis?.skippedVision == [])
        #expect(items["burst0"]?.analysis?.skippedVision == [])
        #expect(items["soloSharp"]?.analysis?.skippedVision == .all)
        #expect(items["soloSoft"]?.analysis?.skippedVision == .featurePrint)
        #expect(items["shot"]?.analysisSource == .metadataOnly)
    }

    @Test func burstsAreListedBeforeAnyPhotoIsOpened() async throws {
        let lib = FakePhotoLibrary()
        lib.previewDelay = .seconds(3)  // no photo finishes within this test's assertions
        for k in 0..<3 {
            lib.add(
                Make.meta("f\(k)", date: at(Double(k)), burst: "B", represents: k == 1),
                preview: .local(image))
        }
        lib.add(Make.meta("other", date: at(50_000)), preview: .local(image))
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: RequestLog(), profile: .phone, policy: fast,
            tiered: true, deepWait: { nil })
        var first: ScanProgress?
        for await p in await scanner.startFullScan() {
            first = p
            break
        }
        #expect((first?.publishedRevision ?? 0) > 0)
        #expect(first?.tier == .photos)
        #expect(lib.previewRequests.isEmpty)
        let summaries = try await store.itemSummaries()
        #expect(Set(summaries.map(\.assetID)) == ["f0", "f1", "f2"])
        #expect(summaries.allSatisfy { $0.analysisSource == .metadataOnly })

        let results = try await ResultsLoader(
            store: store, builder: DefaultResultsBuilder(detectors: StandardPipeline.detectors())
        ).load()
        let group = try #require(results.category(.bursts)?.groups.first)
        #expect(Set(group.members) == ["f0", "f1", "f2"])
        // Nothing is analyzed, so the keeper is the frame Photos shows.
        #expect(group.keepers == ["f1"])
        await scanner.stop()
    }

    @Test func aDeepCheckThatWaitsIsOwedAndStartsOnRequest() async throws {
        let lib = library()
        let log = RequestLog(sharpness: Self.softOnes)
        let store = try InMemoryStore.make()
        let scanner = tieredScanner(lib, store: store, log: log, wait: .lowPowerMode)
        let events = await drain(await scanner.startFullScan())

        let last = try #require(events.last)
        #expect(last.state == .completed && last.tier == .photos)
        #expect(last.deepRemaining == Self.owedAfterThePhotoCheck.count)
        #expect(last.deepWait == .lowPowerMode)
        #expect(ScanTierStatus(last)?.deep == .waitingFor(.lowPowerMode))
        #expect(try await store.sessions().map(\.tier) == [.photos])
        for id in ["pairA", "pairB", "soloSharp", "soloSoft", "burst0", "burst1", "burst2"] {
            #expect(log.requests(id) == [.exact], "\(id)")
        }

        // The person asks for it: only the owed photos, whatever made it wait.
        let deep = await drain(await scanner.startDeepScan())
        let end = try #require(deep.last)
        #expect(end.state == .completed && end.tier == .deep && end.deepRemaining == 0)
        #expect(end.total == 6 && end.processed == 6)
        for id in Self.owedAfterThePhotoCheck {
            #expect(log.requests(id).count == 2, "\(id)")
            #expect(log.requests(id).last?.contains(.exact) == false, "\(id)")
        }
        #expect(log.requests("soloSharp") == [.exact])
        #expect(try await store.sessions().map(\.tier) == [.deep, .photos])

        // Nothing is owed any more: asking again plans nothing.
        let again = await drain(await scanner.startDeepScan())
        #expect(again.last?.total == 0 && again.last?.state == .completed)
        #expect(log.requests("pairA").count == 2)
    }

    @Test func aQuickCheckLeavesTheBacklogAlone() async throws {
        let lib = library()
        let log = RequestLog(sharpness: Self.softOnes)
        let store = try InMemoryStore.make()
        let scanner = tieredScanner(lib, store: store, log: log, wait: .lowPowerMode)
        _ = await drain(await scanner.startFullScan())

        // A photo far from every other: analyzed, and none of the backlog is touched.
        lib.add(Make.meta("fresh", date: at(50_000)), preview: .local(image))
        let check = await scanner.quickCheck()
        #expect(check.state == .completed && check.deepRemaining == 6)
        #expect(log.requests("fresh") == [[]])
        for id in Self.owedAfterThePhotoCheck { #expect(log.requests(id) == [.exact], "\(id)") }

        // A photo next to the pair: the pair is analyzed with it, the rest is still owed.
        lib.add(Make.meta("pairC", date: at(30)), preview: .local(image))
        let again = await scanner.quickCheck()
        #expect(log.requests("pairC") == [.all])
        #expect(log.requests("pairA") == [.exact, .all])
        #expect(log.requests("pairB") == [.exact, .all])
        for id in ["soloSoft", "burst0", "burst1", "burst2"] {
            #expect(log.requests(id) == [.exact], "\(id)")
        }
        #expect(again.deepRemaining == 4)
        #expect(try await store.sessions().allSatisfy { $0.tier == nil || $0.tier == .photos })
    }

    @Test func aStoredDeepJobResumesAsTheDeepJob() async throws {
        let lib = library()
        let log = RequestLog(sharpness: Self.softOnes)
        let store = try InMemoryStore.make()
        let waiting = tieredScanner(lib, store: store, log: log, wait: .lowPowerMode)
        _ = await drain(await waiting.startFullScan())

        // A deep job that was planned and then interrupted.
        let plan = ScanPlanner.plan(
            library: await lib.fetchAllItems(), stored: try await store.itemSummaries(),
            kind: .quickCheck, policy: fast, scope: .deep)
        let job = ScanSession(
            kind: .full, state: .paused, totalItems: plan.toAnalyze.count, tier: .deep)
        let chunks = ScanPlanner.chunks(
            jobID: job.id, assetIDs: plan.toAnalyze.map(\.assetID), size: 4,
            skipVision: plan.skipVision)
        try await store.createJob(job, chunks: chunks)
        #expect(chunks.count == 2)

        let resumed = tieredScanner(lib, store: store, log: log)
        let events = await drain(await resumed.startFullScan())
        let last = try #require(events.last)
        #expect(last.tier == .deep && last.state == .completed && last.processed == 6)
        // The photo check was not run again, and no third job was planned.
        #expect(events.allSatisfy { $0.tier == .deep })
        #expect(try await store.sessions().map(\.tier) == [.deep, .photos])
        for id in Self.owedAfterThePhotoCheck { #expect(log.requests(id).count == 2, "\(id)") }
    }

    @Test func withoutTheFlagAScanIsTheOnePassScanItWas() async throws {
        let lib = library()
        let log = RequestLog(sharpness: Self.softOnes)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: log, profile: .phone, policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.allSatisfy { $0.tier == nil && $0.deepRemaining == 0 })
        #expect(events.last?.state == .completed && events.last?.total == 9)
        #expect(try await store.sessions().map(\.tier) == [nil])
        // Every photo was asked once, for the work the library demands, and nothing was forbidden.
        #expect(log.requests("pairA") == [.all] && log.requests("burst2") == [.all])
        #expect(log.requests("soloSharp") == [[]])
        #expect(log.requests("soloSoft") == [[]])
        let items = Dictionary(
            uniqueKeysWithValues: try await store.items().map { ($0.assetID, $0) })
        #expect(items["soloSoft"]?.analysis?.skippedVision == .featurePrint)
    }

    // MARK: A tiered scan equals a one-pass scan

    func scan(
        _ lib: FakePhotoLibrary, store: SwiftDataStore, analyzer: any Analyzer,
        profile: ScanProfile, tiered: Bool, quick: Bool = false
    ) async throws {
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: analyzer, profile: profile, progressEvery: 5,
            policy: fast, tiered: tiered, deepWait: { nil })
        if quick {
            let progress = await scanner.quickCheck()
            #expect(progress.state == .completed)
        } else {
            var last: ScanProgress?
            for await p in await scanner.startFullScan() { last = p }
            #expect(last?.state == .completed)
            #expect(last?.processed == last?.total)
        }
    }

    @Test(arguments: DeferredVisionTests.profiles, [false, true])
    func aTieredScanEndsWhereAOnePassScanEnds(profile: ScanProfile, quick: Bool) async throws {
        let help = DeferredVisionTests()
        // Stage one, tiered: the photo check asks for no Vision work, the deep check for what is owed.
        let lib = FakePhotoLibrary()
        help.firstBatch(lib)
        let faker = DeferredVisionTests.FaceFaker()
        let tiered = try InMemoryStore.make()
        try await scan(lib, store: tiered, analyzer: faker, profile: profile, tiered: true)
        for id in ["solo1", "gap61a", "dupA", "dupA-copy", "blur0", "undated"] {
            #expect(faker.requests(id).first == .exact, "\(id)")
        }
        for id in ["pair60a", "pair60b", "burstA0", "fr0", "fr2"] {
            #expect(faker.requests(id) == [.exact, .all], "\(id)")
        }
        for id in ["farB0", "farB1", "loneBurst"] {
            #expect(faker.requests(id) == [.exact, .faceQuality], "\(id)")
        }

        // Stage two: photos arrive and change, then the library is scanned again.
        help.secondBatch(lib)
        try await scan(
            lib, store: tiered, analyzer: faker, profile: profile, tiered: true, quick: quick)

        // The same final library, scanned once in one pass.
        let finalLib = FakePhotoLibrary()
        help.firstBatch(finalLib)
        help.secondBatch(finalLib)
        let oneShot = try InMemoryStore.make()
        try await scan(
            finalLib, store: oneShot, analyzer: DeferredVisionTests.FaceFaker(),
            profile: profile, tiered: false)

        let a = try await help.results(tiered)
        let b = try await help.results(oneShot)
        #expect(!a.categories.isEmpty)
        #expect(a.group(containing: "solo2")?.members.contains("arr2") == true)
        #expect(a.group(containing: "solo4")?.members.contains("moveme") == true)
        #expect(a.categories == b.categories)
        #expect(a.defaultSelection == b.defaultSelection)
        #expect(a.notScannedCount == b.notScannedCount)
        #expect(a.slimmed() == b.slimmed())

        // Photo by photo, what a detector reads is what a one-pass scan stores.
        let tieredItems = Dictionary(
            uniqueKeysWithValues: try await tiered.items().map { ($0.assetID, $0) })
        let oneShotItems = Dictionary(
            uniqueKeysWithValues: try await oneShot.items().map { ($0.assetID, $0) })
        #expect(Set(tieredItems.keys) == Set(oneShotItems.keys))
        for (id, x) in tieredItems {
            let y = try #require(oneShotItems[id])
            #expect(x.analysisSource == y.analysisSource, "\(id)")
            #expect(x.analysis?.dHash == y.analysis?.dHash, "\(id)")
            #expect(x.analysis?.sharpness == y.analysis?.sharpness, "\(id)")
            #expect(x.analysis?.skippedVision == y.analysis?.skippedVision, "\(id)")
            #expect(x.analysis?.faceQuality == y.analysis?.faceQuality, "\(id)")
        }
    }
}
