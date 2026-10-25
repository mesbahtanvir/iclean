import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Spec 010: the feature print and face quality are computed only for photos a detector can read
/// them for, and the scan finds exactly what it found when it computed them for every photo.
@Suite struct DeferredVisionTests {
    let fast = ScanRetryPolicy(
        chunkSize: 16, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .seconds(20), crashBudget: 5, crossScanAttempts: 6)
    let t0 = 1_600_000_000.0

    /// The phone profile as shipped, and a wide one with lanes and write-behind like the Mac's.
    static let profiles: [ScanProfile] = [
        .phone,
        ScanProfile(
            name: "mac-like", concurrency: 8, lanes: 4, chunkSize: 16, writeBehind: 6,
            buildParallelism: 4),
    ]

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: t0 + seconds) }

    // MARK: Who needs what

    @Test func aPhotoNeedsVisionOnlyWithANeighbourWithinAMinuteOrABurst() {
        let library = [
            Make.meta("alone", date: at(0)),
            Make.meta("a", date: at(10_000)), Make.meta("b", date: at(10_030)),
            // Exactly the window apart is a neighbour; a hair more is not.
            Make.meta("edge1", date: at(20_000)), Make.meta("edge2", date: at(20_060)),
            Make.meta("far1", date: at(30_000)), Make.meta("far2", date: at(30_060.5)),
            Make.meta("burst", date: at(40_000), burst: "B"),
            Make.meta("twin1", date: at(50_000)), Make.meta("twin2", date: at(50_000)),
            Make.meta("live", kind: .livePhoto, date: at(60_000)),
            Make.meta("liveMate", date: at(60_010)),
            // Videos and screenshots are not seen by the similar-shots detector.
            Make.meta("lonely", date: at(70_000)),
            Make.meta("clip", kind: .video, date: at(70_005), duration: 9),
            Make.meta("shot", kind: .screenshot, date: at(70_010)),
        ]
        let demand = VisionDemand(library: library)
        func work(_ id: String) -> VisionWork {
            demand.work(for: library.first { $0.assetID == id }!)
        }
        #expect(work("alone") == [])
        #expect(work("a") == .all && work("b") == .all)
        #expect(work("edge1") == .all && work("edge2") == .all)
        #expect(work("far1") == [] && work("far2") == [])
        #expect(work("burst") == .faceQuality)
        #expect(work("twin1") == .all && work("twin2") == .all)
        #expect(work("live") == .all && work("liveMate") == .all)
        #expect(work("lonely") == [])
        #expect(work("clip") == [] && work("shot") == [])
        #expect(demand.skipped(for: library.first { $0.assetID == "alone" }!) == .all)
        #expect(demand.skipped(for: library.first { $0.assetID == "burst" }!) == .featurePrint)
    }

    @Test func aPhotoWithoutADateHasNoNeighbours() {
        let undated = AssetMetadata(
            assetID: "undated", kind: .photo, captureDate: nil, pixelWidth: 10, pixelHeight: 10)
        let library = [undated, Make.meta("other", date: Date(timeIntervalSince1970: 0))]
        let demand = VisionDemand(library: library)
        #expect(demand.work(for: undated) == [])
        #expect(demand.work(for: library[1]) == [])
    }

    // MARK: The plan

    func summary(_ m: AssetMetadata, skipped: VisionWork) -> StoredItemSummary {
        StoredItemSummary(metadata: m, analysisSource: .localPreview, skippedVision: skipped)
    }

    @Test func aPlanSkipsVisionForPhotosNothingCanGroup() {
        let library = [
            Make.meta("alone", date: at(0)), Make.meta("n1", date: at(5_000)),
            Make.meta("n2", date: at(5_020)), Make.meta("burst", date: at(9_000), burst: "B"),
            Make.meta("shot", kind: .screenshot, date: at(12_000)),
        ]
        let plan = ScanPlanner.plan(library: library, stored: [], kind: .full, policy: .default)
        #expect(plan.skipVision["alone"] == .all)
        #expect(plan.skipVision["burst"] == .featurePrint)
        #expect(plan.skipVision["n1"] == nil && plan.skipVision["n2"] == nil)
        // A screenshot is never analyzed, so nothing is asked of Vision for it either.
        #expect(plan.skipVision["shot"] == nil)
        #expect(plan.repairs.isEmpty)

        let complete = ScanPlanner.plan(
            library: library, stored: [], kind: .full, policy: .default, deferVision: false)
        #expect(complete.skipVision.isEmpty)
    }

    @Test func aStoredPhotoWhoseNeighbourArrivedIsPlannedAgain() {
        let stored = Make.meta("old", date: at(0))
        let arrived = Make.meta("new", date: at(20))
        for kind in [ScanKind.full, .quickCheck] {
            let plan = ScanPlanner.plan(
                library: [stored, arrived], stored: [summary(stored, skipped: .all)], kind: kind,
                policy: .default)
            #expect(plan.repairs.map(\.assetID) == ["old"], "\(kind)")
            #expect(Set(plan.toAnalyze.map(\.assetID)) == ["old", "new"], "\(kind)")
            // Both have a neighbour now, so both get all of their Vision work.
            #expect(plan.skipVision.isEmpty, "\(kind)")
        }
    }

    @Test func aStoredPhotoIsLeftAloneWhenWhatItSkippedIsStillNotWanted() {
        let stored = Make.meta("old", date: at(0))
        let far = Make.meta("new", date: at(61))
        let plan = ScanPlanner.plan(
            library: [stored, far], stored: [summary(stored, skipped: .all)], kind: .full,
            policy: .default)
        #expect(plan.repairs.isEmpty)
        #expect(plan.toAnalyze.map(\.assetID) == ["new"])
        #expect(plan.skipVision["new"] == .all)

        // A photo that skipped nothing is never repaired, whatever arrives next to it.
        let complete = ScanPlanner.plan(
            library: [stored, Make.meta("next", date: at(5))],
            stored: [summary(stored, skipped: [])], kind: .full, policy: .default)
        #expect(complete.repairs.isEmpty)
        #expect(complete.toAnalyze.map(\.assetID) == ["next"])

        // Neither does a plan that does not defer repair anything.
        let off = ScanPlanner.plan(
            library: [stored, Make.meta("next", date: at(5))],
            stored: [summary(stored, skipped: .all)], kind: .full, policy: .default,
            deferVision: false)
        #expect(off.repairs.isEmpty)
    }

    @Test func aChangedDateOrBurstRepairsEvenIfTheModificationDateIsTheSame() {
        let modified = at(0)
        let a = Make.meta("a", date: at(0), modified: modified)
        let b = Make.meta("b", date: at(50_000), modified: modified)
        let c = Make.meta("c", date: at(90_000), modified: modified)
        let stored = [
            summary(a, skipped: .all), summary(b, skipped: .all), summary(c, skipped: .all),
        ]
        // b is moved next to a; c gets a burst. Neither changes its modification date.
        var movedB = b
        movedB.captureDate = at(30)
        var burstC = c
        burstC.burstID = "late"
        let plan = ScanPlanner.plan(
            library: [a, movedB, burstC], stored: stored, kind: .quickCheck, policy: .default)
        #expect(Set(plan.repairs.map(\.assetID)) == ["a", "b", "c"])
        #expect(plan.refreshed.isEmpty)
        // c has a burst but no neighbour: it still wants its face score, and skips the print.
        #expect(plan.skipVision["c"] == .featurePrint)
    }

    @Test func aPhotoThatWasNotAnalyzedIsNotARepair() {
        let stored = Make.meta("old", date: at(0))
        let state = StoredItemSummary(
            metadata: stored, analysisSource: .notScanned, scanAttempts: 6,
            skippedVision: .all)
        let plan = ScanPlanner.plan(
            library: [stored, Make.meta("new", date: at(5))], stored: [state], kind: .full,
            policy: .default)
        #expect(plan.repairs.isEmpty)
    }

    @Test func chunksCarryThePlansDecisionForTheirOwnItems() {
        let ids = (0..<40).map { "p\($0)" }
        let skip: [String: VisionWork] = ["p0": .all, "p3": .featurePrint, "p35": .all]
        let chunks = ScanPlanner.chunks(jobID: UUID(), assetIDs: ids, size: 32, skipVision: skip)
        #expect(chunks[0].skippedVision(at: 0) == .all)
        #expect(chunks[0].skippedVision(at: 3) == .featurePrint)
        #expect(chunks[0].skippedVision(at: 1) == [])
        #expect(chunks[1].skippedVision(at: 3) == .all)  // p35
        #expect(chunks[1].skipPrintMask == 1 << 3 && chunks[1].skipFaceMask == 1 << 3)
        let plain = ScanPlanner.chunks(jobID: UUID(), assetIDs: ids, size: 32)
        #expect(plain.allSatisfy { $0.skipPrintMask == 0 && $0.skipFaceMask == 0 })
    }

    // MARK: The store

    @Test func theSkipRecordSurvivesTheStoreAndIsClearedByAnalysisThatDidTheWork() async throws {
        let store = try InMemoryStore.make()
        var skipped = Make.item(Make.meta("s", date: at(0)))
        skipped.analysis?.skippedVision = .all
        var partial = Make.item(Make.meta("p", date: at(5_000), burst: "B"))
        partial.analysis?.skippedVision = .featurePrint
        let plain = Make.item(Make.meta("c", date: at(9_000)), print: Data([1]))
        try await store.upsert([skipped, partial, plain])

        let full = Dictionary(
            uniqueKeysWithValues: try await store.items().map { ($0.assetID, $0) })
        #expect(full["s"]?.analysis?.skippedVision == .all)
        #expect(full["p"]?.analysis?.skippedVision == .featurePrint)
        #expect(full["c"]?.analysis?.skippedVision == [])
        let lean = Dictionary(
            uniqueKeysWithValues: try await store.itemsWithoutFeaturePrints().map {
                ($0.assetID, $0)
            })
        #expect(lean["s"]?.analysis?.skippedVision == .all)
        let summaries = Dictionary(
            uniqueKeysWithValues: try await store.itemSummaries().map { ($0.assetID, $0) })
        #expect(summaries["s"]?.skippedVision == .all)
        #expect(summaries["p"]?.skippedVision == .featurePrint)
        #expect(summaries["c"]?.skippedVision == [])

        // The analysis done again, with the work done, clears it.
        var repaired = skipped
        repaired.analysis?.skippedVision = []
        repaired.analysis?.featurePrint = Data([7])
        try await store.upsert([repaired])
        #expect(try await store.itemSummaries().first { $0.assetID == "s" }?.skippedVision == [])
    }

    @Test func aFailedRequestIsNotASkippedOne() async throws {
        // An empty print with no record is Vision being unavailable; it is never repaired.
        let item = Make.item(Make.meta("u", date: at(0)))
        #expect(item.analysis?.featurePrint.isEmpty == true)
        #expect(item.analysis?.skippedVision == [])
        let m = item.metadata
        let plan = ScanPlanner.plan(
            library: [m, Make.meta("next", date: at(5))],
            stored: [summary(m, skipped: [])], kind: .full, policy: .default)
        #expect(plan.repairs.isEmpty)
    }

    @Test func chunksKeepTheirMasksInTheStore() async throws {
        let store = try InMemoryStore.make()
        let ids = (0..<40).map { "p\($0)" }
        let job = ScanSession(kind: .full, state: .running, totalItems: 40)
        let chunks = ScanPlanner.chunks(
            jobID: job.id, assetIDs: ids, size: 32,
            skipVision: ["p1": .all, "p2": .faceQuality, "p31": .featurePrint, "p39": .all])
        try await store.createJob(job, chunks: chunks)
        let back = try await store.chunks(job: job.id)
        #expect(back == chunks)
        #expect(back[0].skippedVision(at: 2) == .faceQuality)
        #expect(back[0].skippedVision(at: 31) == .featurePrint)
        #expect(back[1].skippedVision(at: 7) == .all)
        // A chunk with nothing to skip reads as zero masks, as a chunk from an earlier build does.
        let none = ScanPlanner.chunks(jobID: job.id, assetIDs: ["x"], size: 32)
        try await store.saveChunks(
            none.map {
                var c = $0; c.sequence = 9; return c
            }, session: nil)
        let nothing = try await store.chunks(job: job.id).first { $0.sequence == 9 }
        #expect(nothing?.skipPrintMask == 0 && nothing?.skipFaceMask == 0)
    }

    // MARK: The analyzer

    /// Records what each photo was asked for and answers like `StubAnalyzer`. Optionally honours
    /// the request (a real analyzer does) or ignores it (every older fake does).
    final class Recorder: Analyzer, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String: VisionWork] = [:]
        let honours: Bool

        init(honours: Bool = true) { self.honours = honours }

        var requests: [String: VisionWork] { lock.withLock { asked } }

        func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
            try await analyze(image, metadata: metadata, vision: .all)
        }

        func analyze(_ image: CGImage, metadata: AssetMetadata, vision: VisionWork) async throws
            -> Analysis
        {
            lock.withLock { asked[metadata.assetID] = vision }
            let skipped = honours ? VisionWork.all.subtracting(vision) : []
            return Analysis(
                dHash: UInt64(image.width), featurePrint: Data(), sharpness: 100,
                skippedVision: skipped)
        }
    }

    /// An analyzer that knows nothing of the request, like the fakes written before spec 010.
    struct OldFashioned: Analyzer {
        func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
            Analysis(dHash: 1, featurePrint: Data(), sharpness: 100)
        }
    }

    @Test func anAnalyzerThatIgnoresTheRequestDoesAllTheWorkAndIsNeverFlagged() async throws {
        let lib = FakePhotoLibrary()
        let image = TestImages.scene(seed: 3, width: 64, height: 48)
        lib.add(Make.meta("alone", date: at(0)), preview: .local(image))
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: OldFashioned(), concurrency: 2, chunkSize: 4,
            policy: fast)
        for await _ in await scanner.startFullScan() {}
        let item = try #require(try await store.items().first)
        #expect(item.analysis?.skippedVision == [])
    }

    @Test func theScanAsksTheAnalyzerForExactlyTheWorkThePlanKept() async throws {
        let image = TestImages.scene(seed: 3, width: 64, height: 48)
        let lib = FakePhotoLibrary()
        for (id, date, burst) in [
            ("alone", 0.0, nil), ("n1", 5_000.0, nil), ("n2", 5_030.0, nil),
            ("burst", 9_000.0, "B" as String?),
        ] {
            lib.add(Make.meta(id, date: at(date), burst: burst), preview: .local(image))
        }
        lib.add(Make.meta("shot", kind: .screenshot, date: at(12_000)), preview: .local(image))
        for profile in Self.profiles {
            let recorder = Recorder()
            let store = try InMemoryStore.make()
            let scanner = ScanPipeline(
                library: lib, store: store, analyzer: recorder, profile: profile, policy: fast)
            for await _ in await scanner.startFullScan() {}
            #expect(
                recorder.requests == [
                    "alone": [], "n1": .all, "n2": .all, "burst": .faceQuality,
                ], "\(profile.name)")
            let items = Dictionary(
                uniqueKeysWithValues: try await store.items().map { ($0.assetID, $0) })
            #expect(items["alone"]?.analysis?.skippedVision == .all)
            #expect(items["burst"]?.analysis?.skippedVision == .featurePrint)
            #expect(items["n1"]?.analysis?.skippedVision == [])
            #expect(items["shot"]?.analysisSource == .metadataOnly)

            // The complete scan asks for everything.
            let all = Recorder()
            let scanner2 = ScanPipeline(
                library: lib, store: try InMemoryStore.make(), analyzer: all, profile: profile,
                policy: fast, deferVision: false)
            for await _ in await scanner2.startFullScan() {}
            #expect(all.requests.values.allSatisfy { $0 == .all })
        }
    }

    @Test func aResumedJobKeepsItsDecisionsWithoutListingTheLibrary() async throws {
        // A paused job planned by this build: the library is not enumerated to resume it.
        let image = TestImages.scene(seed: 3, width: 64, height: 48)
        let lib = FakePhotoLibrary()
        var ids: [String] = []
        for i in 0..<40 {
            let id = "p\(i)"
            ids.append(id)
            // Pairs, so that half of the photos have a neighbour.
            lib.add(
                Make.meta(id, date: at(Double(i / 2) * 1_000 + Double(i % 2) * 5)),
                preview: .local(image))
        }
        for i in 40..<48 {
            let id = "p\(i)"
            ids.append(id)
            lib.add(Make.meta(id, date: at(Double(i) * 10_000)), preview: .local(image))
        }
        let plan = ScanPlanner.plan(
            library: await lib.fetchAllItems(), stored: [], kind: .full, policy: fast)
        let listings = lib.fetchAllItemsCalls
        #expect(plan.skipVision.count == 8)
        let session = ScanSession(kind: .full, state: .paused, totalItems: 48)
        let chunks = ScanPlanner.chunks(
            jobID: session.id, assetIDs: plan.toAnalyze.map(\.assetID), size: 16,
            skipVision: plan.skipVision)
        let store = try InMemoryStore.make()
        try await store.createJob(session, chunks: chunks)
        let recorder = Recorder()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: recorder, concurrency: 3, chunkSize: 16,
            policy: fast)
        for await _ in await scanner.startFullScan() {}
        #expect(lib.fetchAllItemsCallsAtFirstPreview == listings)
        #expect(recorder.requests.count == 48)
        for (id, work) in recorder.requests {
            #expect(work == VisionWork.all.subtracting(plan.skipVision[id] ?? []), "\(id)")
        }
        #expect(recorder.requests.values.filter { $0 == [] }.count == 8)
    }

    @Test func aChunkThatRunsAloneAfterACrashStillSkipsWhatThePlanSkipped() async throws {
        let image = TestImages.scene(seed: 3, width: 64, height: 48)
        let lib = FakePhotoLibrary()
        for i in 0..<6 {
            lib.add(Make.meta("p\(i)", date: at(Double(i) * 10_000)), preview: .local(image))
        }
        let session = ScanSession(kind: .full, state: .running, totalItems: 6, crashCount: 1)
        var chunks = ScanPlanner.chunks(
            jobID: session.id, assetIDs: lib.allIDs, size: 32,
            skipVision: Dictionary(uniqueKeysWithValues: lib.allIDs.map { ($0, VisionWork.all) }))
        chunks[0].state = .running
        chunks[0].owner = UUID()
        chunks[0].crashes = 1
        chunks[0].isolate = true
        let store = try InMemoryStore.make()
        try await store.createJob(session, chunks: chunks)
        let recorder = Recorder()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: recorder, concurrency: 3, chunkSize: 32,
            policy: fast)
        for await _ in await scanner.startFullScan() {}
        #expect(recorder.requests.count == 6)
        #expect(recorder.requests.values.allSatisfy { $0 == [] })
    }

    // MARK: Detector and builder

    @Test func twoPhotosWhosePrintWasSkippedAreNotGroupedOnTheirThumbprintsAlone() {
        let base = TestImages.scene(seed: 5, width: 96, height: 72)
        let print = Thumbprint.compute(base)
        func photo(_ id: String, _ t: Double, skipped: VisionWork) -> LibraryItem {
            var item = Make.item(Make.meta(id, date: at(t)), thumbprint: print)
            item.analysis?.skippedVision = skipped
            return item
        }
        let detector = SimilarShotsDetector()
        // The control: nothing was skipped and Vision was unavailable, so the thumbprints decide.
        let control = detector.detect(items: [
            photo("a", 0, skipped: []), photo("b", 10, skipped: []),
        ])
        #expect(control.count == 1)
        // Skipped for one of them: the pair waits for the repair instead of being guessed.
        let skipped = detector.detect(items: [
            photo("a", 0, skipped: .featurePrint), photo("b", 10, skipped: []),
        ])
        #expect(skipped.isEmpty)
        // Frames of one burst are the Bursts category's (spec 015), with or without a print.
        var x = photo("x", 0, skipped: .all)
        x.metadata.burstID = "B"
        var y = photo("y", 3_000, skipped: .all)
        y.metadata.burstID = "B"
        #expect(detector.detect(items: [x, y]).isEmpty)
        #expect(BurstDetector().detect(items: [x, y]).count == 1)
    }

    @Test func resultsKeepFaceQualityOnlyWhereAKeeperIsChosenFromIt() {
        func photo(
            _ id: String, _ t: Double, face: Double?, seed: UInt64, burst: String? = nil
        ) -> LibraryItem {
            // Different scenes and hashes, so no two of them are duplicates of each other.
            Make.item(
                Make.meta(id, date: at(t), burst: burst), dHash: seed &* 0x9E37_79B9_7F4A_7C15,
                thumbprint: Thumbprint.compute(TestImages.scene(seed: seed, width: 96, height: 72)),
                sharpness: 0.8, face: face)
        }
        // A burst pair (a Bursts group since spec 015) and a blurry photo that has a face score.
        var blurry = photo("blurry", 50_000, face: 0.4, seed: 3)
        blurry.analysis?.sharpness = 0.01
        let items = [
            photo("s1", 0, face: 0.2, seed: 1, burst: "B"),
            photo("s2", 20_000, face: 0.9, seed: 2, burst: "B"), blurry,
        ]
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: items, keepMarks: [])
        #expect(results.category(.bursts) != nil)
        #expect(results.items["s1"]?.analysis?.faceQuality == 0.2)
        #expect(results.items["s2"]?.analysis?.faceQuality == 0.9)
        #expect(results.category(.blurry) != nil)
        #expect(results.items["blurry"]?.analysis?.faceQuality == nil)
    }

    // MARK: A library scanned in two stages equals one scanned at once

    /// Adds a face score to the photos that were asked for one (the test images have no faces) and
    /// makes the frames of a scene equally sharp, so the face score decides their keeper. Everything
    /// else is the real analyzer, Vision included, and it records what it was asked for.
    final class FaceFaker: Analyzer, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String: [VisionWork]] = [:]

        func requests(_ id: String) -> [VisionWork] { lock.withLock { asked[id] ?? [] } }

        func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
            try await analyze(image, metadata: metadata, vision: .all)
        }

        func analyze(_ image: CGImage, metadata: AssetMetadata, vision: VisionWork) async throws
            -> Analysis
        {
            lock.withLock { asked[metadata.assetID, default: []].append(vision) }
            var a = try await DefaultAnalyzer().analyze(image, metadata: metadata, vision: vision)
            if metadata.assetID.hasPrefix("fr") { a.sharpness = 0.8 }
            // The analyzer may run the face pass for a photo it was not asked to (a soft photo the
            // Unimportant list reads, spec 011): fake what it says it did, not what was asked.
            if !a.skippedVision.contains(.faceQuality), metadata.kind == .photo {
                var h: UInt64 = 1_469_598_103_934_665_603
                for b in metadata.assetID.utf8 { h = (h ^ UInt64(b)) &* 1_099_511_628_211 }
                a.faceQuality = Double(h % 997) / 997
            }
            return a
        }
    }

    func scene(_ seed: UInt64, step: Int = 0) -> CGImage {
        let base = TestImages.scene(seed: seed, width: 160, height: 120)
        return step == 0 ? base : TestImages.withSubject(base, seed: seed, step: step)
    }

    /// The library before: photos taken alone, in pairs, in bursts, copies, blurred ones, a
    /// screenshot and a video.
    func firstBatch(_ lib: FakePhotoLibrary) {
        func put(
            _ id: String, _ t: Double?, _ image: CGImage, kind: ItemKind = .photo,
            burst: String? = nil, width: Int = 4032, height: Int = 3024, duration: Double? = nil
        ) {
            let date = t.map { at($0) }
            lib.add(
                AssetMetadata(
                    assetID: id, kind: kind, captureDate: date, modificationDate: date ?? at(0),
                    pixelWidth: width, pixelHeight: height, duration: duration, burstID: burst),
                preview: .local(image))
        }
        for k in 0..<10 { put("solo\(k)", Double(k) * 10_000, scene(UInt64(k) + 1)) }
        put("pair60a", 200_000, scene(50))
        put("pair60b", 200_060, scene(50, step: 1))
        put("gap61a", 210_000, scene(51))
        put("gap61b", 210_061, scene(51, step: 1))
        for k in 0..<3 {
            put("burstA\(k)", 220_000 + Double(k) * 2, scene(52, step: k), burst: "BA")
        }
        put("farB0", 230_000, scene(53), burst: "BF")
        put("farB1", 237_200, scene(53, step: 1), burst: "BF")
        put("loneBurst", 240_000, scene(54), burst: "BL")
        put("dupA", 250_000, scene(55))
        put(
            "dupA-copy", 253_600, TestImages.resized(scene(55), scale: 0.5), width: 2016,
            height: 1512)
        put("blur0", 260_000, TestImages.blurred(scene(56)))
        put("blur1", 270_000, TestImages.blurred(scene(57)))
        put("undated", nil, scene(58))
        put("moveme", 300_000, scene(5, step: 1))  // a frame of solo4's scene, taken elsewhere
        for k in 0..<3 { put("fr\(k)", 280_000 + Double(k) * 5, scene(59, step: k)) }
        put("shot0", 290_000, scene(60), kind: .screenshot, width: 1206, height: 2622)
        put("vid0", 295_000, scene(61), kind: .video, duration: 12)
    }

    /// What arrives later: photos next to stored photos that have no print, a photo moved next to
    /// another, a burst assigned to a stored photo, photos that change nothing, one that leaves.
    func secondBatch(_ lib: FakePhotoLibrary) {
        func put(
            _ id: String, _ t: Double, _ image: CGImage, kind: ItemKind = .photo,
            burst: String? = nil
        ) {
            lib.add(
                Make.meta(id, kind: kind, date: at(t), burst: burst), preview: .local(image))
        }
        put("arr2", 20_020, scene(3, step: 1))  // 20 s after solo2
        put("arr5", 50_059, scene(6, step: 1))  // 59 s after solo5
        put("arr7", 70_060, scene(8, step: 1))  // exactly 60 s after solo7
        put("arr61", 210_091, scene(51, step: 2))  // 30 s after gap61b, 91 s after gap61a
        put("arrFar", 237_210, scene(53, step: 2))  // 10 s after farB1
        put("arrBurst", 500_000, scene(70), burst: "BNEW")
        put("arrSolo", 600_000, scene(71))
        put("arrShot", 610_000, scene(72), kind: .screenshot)
        // Metadata changes without a new modification date.
        lib.update("solo9") { $0.burstID = "BNEW" }  // gets a burst mate far away
        lib.update("moveme") { $0.captureDate = self.at(40_015) }  // moved 15 s after solo4
        lib.delete("pair60b")  // pair60a loses its neighbour
    }

    /// The photos the second batch makes demanding: stored without a print or face score, wanted now.
    static let repaired: Set<String> = [
        "solo2", "solo5", "solo7", "gap61b", "farB1", "solo9", "moveme", "solo4",
    ]
    static let arrived: Set<String> = [
        "arr2", "arr5", "arr7", "arr61", "arrFar", "arrBurst", "arrSolo",
    ]

    func scan(
        _ lib: FakePhotoLibrary, store: SwiftDataStore, analyzer: FaceFaker, profile: ScanProfile,
        deferVision: Bool = true, quick: Bool = false
    ) async throws {
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: analyzer, profile: profile, progressEvery: 5,
            policy: fast, deferVision: deferVision)
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

    func results(_ store: SwiftDataStore) async throws -> CleanupResults {
        try await ResultsLoader(
            store: store, builder: DefaultResultsBuilder(detectors: StandardPipeline.detectors())
        ).load()
    }

    func previewsSince(_ lib: FakePhotoLibrary, _ count: Int) -> [String] {
        Array(lib.previewRequests.dropFirst(count))
    }

    @Test(arguments: profiles, [false, true])
    func aLibraryScannedInTwoStagesFindsWhatAOneShotScanFinds(profile: ScanProfile, quick: Bool)
        async throws
    {
        // Stage one, deferred. The photos nothing can group get neither request.
        let lib = FakePhotoLibrary()
        firstBatch(lib)
        let faker = FaceFaker()
        let staged = try InMemoryStore.make()
        try await scan(lib, store: staged, analyzer: faker, profile: profile)
        let first = lib.previewRequests.count
        for id in ["solo1", "gap61a", "dupA", "dupA-copy", "blur0", "undated"] {
            #expect(faker.requests(id) == [[]], "\(id)")
        }
        for id in ["farB0", "farB1", "loneBurst"] {
            #expect(faker.requests(id) == [.faceQuality], "\(id)")
        }
        for id in ["pair60a", "pair60b", "burstA0", "fr0", "fr2"] {
            #expect(faker.requests(id) == [.all], "\(id)")
        }
        let afterFirst = Dictionary(
            uniqueKeysWithValues: try await staged.items().map { ($0.assetID, $0) })
        #expect(afterFirst["solo2"]?.analysis?.featurePrint.isEmpty == true)
        #expect(afterFirst["solo2"]?.analysis?.skippedVision == .all)

        // Stage two: photos arrive and change, then the library is scanned again.
        secondBatch(lib)
        try await scan(lib, store: staged, analyzer: faker, profile: profile, quick: quick)

        // Exactly the new photos and the stored photos they made demanding were analyzed.
        let second = previewsSince(lib, first)
        #expect(Set(second) == Self.arrived.union(Self.repaired))
        #expect(second.count == Set(second).count)
        // Each was first skipped, then asked for what the library now wants: a photo given a burst
        // wants its face score only, the others a neighbour's both.
        for id in Self.repaired {
            #expect(faker.requests(id).count == 2, "\(id)")
            #expect(faker.requests(id).last == (id == "solo9" ? .faceQuality : .all), "\(id)")
        }

        // The same final library scanned once, deferred, and once with every photo's Vision work.
        let finalLib = FakePhotoLibrary()
        firstBatch(finalLib)
        secondBatch(finalLib)
        let oneShot = try InMemoryStore.make()
        try await scan(finalLib, store: oneShot, analyzer: FaceFaker(), profile: profile)
        let complete = try InMemoryStore.make()
        try await scan(
            finalLib, store: complete, analyzer: FaceFaker(), profile: profile, deferVision: false)

        let a = try await results(staged)
        let b = try await results(oneShot)
        let c = try await results(complete)
        #expect(!a.categories.isEmpty)
        // The repaired pair is found: without its print it would not be.
        #expect(a.group(containing: "solo2")?.members.contains("arr2") == true)
        #expect(a.group(containing: "solo4")?.members.contains("moveme") == true)
        #expect(a.group(containing: "farB0") != nil)
        #expect(a.categories == c.categories)
        #expect(a.defaultSelection == c.defaultSelection)
        #expect(a.notScannedCount == c.notScannedCount)
        #expect(a.slimmed() == c.slimmed())
        #expect(b.slimmed() == c.slimmed())

        // Photo by photo, what a detector can read is what a complete scan stores.
        let stagedItems = Dictionary(
            uniqueKeysWithValues: try await staged.items().map { ($0.assetID, $0) })
        let completeItems = Dictionary(
            uniqueKeysWithValues: try await complete.items().map { ($0.assetID, $0) })
        #expect(Set(stagedItems.keys) == Set(completeItems.keys))
        let demand = VisionDemand(library: await finalLib.fetchAllItems())
        for (id, x) in stagedItems {
            let y = try #require(completeItems[id])
            #expect(x.analysisSource == y.analysisSource, "\(id)")
            #expect(x.analysis?.dHash == y.analysis?.dHash, "\(id)")
            #expect(x.analysis?.thumbprint == y.analysis?.thumbprint, "\(id)")
            #expect(x.analysis?.sharpness == y.analysis?.sharpness, "\(id)")
            #expect(x.analysis?.aestheticsScore == y.analysis?.aestheticsScore, "\(id)")
            guard let xa = x.analysis, let ya = y.analysis else { continue }
            // Nothing a detector reads is missing: no skipped work is wanted now.
            #expect(xa.skippedVision.isDisjoint(with: demand.work(for: x.metadata)), "\(id)")
            if !xa.skippedVision.contains(.featurePrint), !xa.featurePrint.isEmpty {
                #expect(FeaturePrint.distance(xa.featurePrint, ya.featurePrint) < 1e-6, "\(id)")
            }
            if !xa.skippedVision.contains(.faceQuality) {
                #expect(xa.faceQuality == ya.faceQuality, "\(id)")
            }
        }
        // A photo that lost its neighbour keeps the print it has; nothing reads it.
        #expect(stagedItems["pair60a"]?.analysis?.featurePrint.isEmpty == false)
        #expect(stagedItems["solo1"]?.analysis?.skippedVision == .all)
    }
}
