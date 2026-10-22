import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Spec 009: a scan that works on many photos, several chunks and several threads finds exactly
/// what a scan that does one thing at a time finds.
@Suite struct ParallelScanTests {
    let fast = ScanRetryPolicy(
        chunkSize: 16, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .seconds(20), crashBudget: 5, crossScanAttempts: 6)
    let image = TestImages.scene(seed: 3, width: 64, height: 48)

    static let narrow = ScanProfile(name: "narrow", concurrency: 1, chunkSize: 16)
    static let wide = ScanProfile(
        name: "wide", concurrency: 8, lanes: 4, chunkSize: 16, writeBehind: 6, buildParallelism: 8)

    /// A library with every shape the detectors care about: screenshots, videos, bursts of three,
    /// a photo with a smaller copy, blurred photos and plain scenes, a few of them favorites.
    func variedLibrary(count: Int) -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        var clock = 1_600_000_000.0
        var n = 0
        func put(
            _ id: String, kind: ItemKind = .photo, image: CGImage, at t: Double,
            width: Int = 4032, height: Int = 3024, burst: String? = nil, favorite: Bool = false,
            duration: Double? = nil
        ) {
            guard lib.allIDs.count < count else { return }
            lib.add(
                Make.meta(
                    id, kind: kind, date: Date(timeIntervalSince1970: t), width: width,
                    height: height, favorite: favorite, duration: duration, burst: burst),
                preview: .local(image))
        }
        while lib.allIDs.count < count {
            clock += 900
            let seed = UInt64(n + 1)
            let base = TestImages.scene(seed: seed, width: 160, height: 120)
            switch n % 10 {
            case 0:
                put(
                    "n\(n)", kind: .screenshot,
                    image: TestImages.stripes(seed: seed, width: 90, height: 160),
                    at: clock, width: 1206, height: 2622)
            case 1:
                put("n\(n)", kind: .video, image: base, at: clock, duration: 12)
            case 2, 3:
                for k in 0..<3 {
                    put(
                        "n\(n)b\(k)", image: TestImages.withSubject(base, seed: seed, step: k),
                        at: clock + Double(k) * 2, burst: n % 10 == 2 ? "B\(n)" : nil)
                }
            case 4:
                put("n\(n)", image: base, at: clock, favorite: n % 20 == 4)
                put(
                    "n\(n)c", image: TestImages.resized(base, scale: 0.5), at: clock + 3_600,
                    width: 2016, height: 1512)
            case 5:
                put("n\(n)", image: TestImages.blurred(base), at: clock)
            default:
                put("n\(n)", image: base, at: clock)
            }
            n += 1
        }
        return lib
    }

    func scan(_ lib: FakePhotoLibrary, profile: ScanProfile) async throws -> SwiftDataStore {
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: DefaultAnalyzer(), profile: profile,
            progressEvery: 5, policy: fast)
        var last: ScanProgress?
        for await p in await scanner.startFullScan() { last = p }
        #expect(last?.state == .completed)
        #expect(last?.processed == last?.total)
        return store
    }

    func results(_ store: SwiftDataStore, parallelism: Int, threshold: Int = 0) async throws
        -> CleanupResults
    {
        await store.setReadParallelism(parallelism)
        // Thresholds of zero send even this small library through the parallel code.
        let detectors: [any CategoryDetector] = [
            DuplicatePhotoDetector(parallelism: parallelism, parallelThreshold: threshold),
            SimilarShotsDetector(parallelism: parallelism, parallelThreshold: threshold),
            BlurDetector(), ScreenshotsCategory(), LargeVideosCategory(),
        ]
        return try await ResultsLoader(
            store: store, builder: DefaultResultsBuilder(detectors: detectors)
        ).load()
    }

    // MARK: Whole scans

    @Test func aWideScanFindsExactlyWhatANarrowScanFinds() async throws {
        let lib = variedLibrary(count: 100)
        let one = try await scan(lib, profile: Self.narrow)
        let many = try await scan(lib, profile: Self.wide)

        // What the analysis stored, photo by photo. The feature print's bytes carry a fresh id each
        // time, so those are compared by distance.
        let a = Dictionary(uniqueKeysWithValues: try await one.items().map { ($0.assetID, $0) })
        let b = Dictionary(uniqueKeysWithValues: try await many.items().map { ($0.assetID, $0) })
        #expect(a.count == 100)
        #expect(Set(a.keys) == Set(b.keys))
        for (id, x) in a {
            let y = try #require(b[id])
            #expect(x.analysisSource == y.analysisSource, "\(id)")
            #expect(x.analysis?.dHash == y.analysis?.dHash, "\(id)")
            #expect(x.analysis?.thumbprint == y.analysis?.thumbprint, "\(id)")
            #expect(x.analysis?.sharpness == y.analysis?.sharpness, "\(id)")
            #expect(x.analysis?.aestheticsScore == y.analysis?.aestheticsScore, "\(id)")
            #expect(x.analysis?.faceQuality == y.analysis?.faceQuality, "\(id)")
            if let p = x.analysis?.featurePrint, let q = y.analysis?.featurePrint, !p.isEmpty,
                !q.isEmpty
            {
                #expect(FeaturePrint.distance(p, q) < 1e-6, "\(id)")
            }
        }

        // The session says the same about both.
        let s1 = try #require(try await one.currentSession())
        let s2 = try #require(try await many.currentSession())
        #expect(s1.processedItems == s2.processedItems)
        #expect(s1.notScannedCount == s2.notScannedCount)
        #expect(s1.failedItems == s2.failedItems)
        #expect(s1.totalItems == s2.totalItems)
        #expect(s2.state == .completed)
        #expect(try await many.chunks(job: s2.id).isEmpty)

        // And so do the results: one thread reading and comparing against many.
        let serial = try await results(one, parallelism: 1)
        let parallel = try await results(many, parallelism: 8)
        #expect(!serial.categories.isEmpty)
        #expect(serial.categories.map(\.category) == parallel.categories.map(\.category))
        for (x, y) in zip(serial.categories, parallel.categories) {
            #expect(x.groups.map(\.id) == y.groups.map(\.id), "\(x.category)")
            #expect(x.groups.map(\.members) == y.groups.map(\.members), "\(x.category)")
            #expect(x.groups.map(\.keepers) == y.groups.map(\.keepers), "\(x.category)")
        }
        #expect(serial.defaultSelection == parallel.defaultSelection)
        #expect(serial.notScannedCount == parallel.notScannedCount)
        #expect(sameListedItems(serial, parallel))

        // The parallel build of the narrow scan's store, and the serial build of the wide one's.
        #expect(sameListedItems(try await results(one, parallelism: 8), serial))
        #expect(sameListedItems(try await results(many, parallelism: 1), serial))
    }

    /// The listed items of two results are the same photos with the same metadata and analysis.
    /// A feature print's stored bytes carry a fresh id with every run, so they are left out.
    func sameListedItems(_ a: CleanupResults, _ b: CleanupResults) -> Bool {
        guard a.categories == b.categories, a.defaultSelection == b.defaultSelection,
            a.notScannedCount == b.notScannedCount, Set(a.items.keys) == Set(b.items.keys)
        else { return false }
        return a.items.allSatisfy { id, x in
            guard let y = b.items[id] else { return false }
            return x.metadata == y.metadata && x.analysisSource == y.analysisSource
                && x.byteSize == y.byteSize && x.analysis?.sharpness == y.analysis?.sharpness
        }
    }

    @Test func theMacProfileIsWideAndThePhoneProfileIsTheOneSpec008Validated() {
        let mac = ScanProfile.mac(cores: 14)
        #expect(mac.concurrency == 14)
        #expect(mac.lanes > 1)
        #expect(mac.writeBehind > 0)
        #expect(mac.buildParallelism == 14)
        let small = ScanProfile.mac(cores: 4)
        #expect(small.concurrency >= 6 && small.lanes >= 2)

        let phone = ScanProfile.phone
        #expect(phone.concurrency == 4)
        #expect(phone.lanes == 1)
        #expect(phone.writeBehind == 0)
        #expect(phone.chunkSize == 32)
        #expect(phone.buildParallelism == 1)
        #expect(!phone.adaptsToConditions)
        #expect(phone.width(thermal: .fair, lowPower: true) == 4)
    }

    @Test func theMacWidthFollowsHeatAndLowPowerButNeverBelowTwo() {
        let mac = ScanProfile.mac(cores: 14)
        #expect(mac.width(thermal: .nominal, lowPower: false) == 14)
        #expect(mac.width(thermal: .fair, lowPower: false) < 14)
        #expect(
            mac.width(thermal: .nominal, lowPower: true)
                < mac.width(thermal: .fair, lowPower: false))
        #expect(mac.width(thermal: .fair, lowPower: true) >= 2)
        #expect(mac.laneWidth(total: 14) * mac.lanes >= 14)
    }

    /// Counts how many analyses run at the same moment.
    final class Gauge: Analyzer, @unchecked Sendable {
        private let lock = NSLock()
        private var running = 0
        private(set) var peak = 0

        func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
            lock.withLock {
                running += 1
                peak = max(peak, running)
            }
            try? await Task.sleep(for: .milliseconds(25))
            lock.withLock { running -= 1 }
            return Analysis(dHash: UInt64(image.width), featurePrint: Data(), sharpness: 100)
        }
    }

    func peakInFlight(
        profile: ScanProfile, thermal: ProcessInfo.ThermalState, lowPower: Bool
    ) async throws -> Int {
        let lib = FakePhotoLibrary()
        for i in 0..<48 { lib.add(Make.meta("g\(i)"), preview: .local(image)) }
        let gauge = Gauge()
        let scanner = ScanPipeline(
            library: lib, store: try InMemoryStore.make(), analyzer: gauge, profile: profile,
            policy: fast, thermalState: { thermal }, lowPowerMode: { lowPower })
        for await _ in await scanner.startFullScan() {}
        return gauge.peak
    }

    @Test func theScanKeepsAsManyPhotosInFlightAsTheProfileSaysAndFewerWhenWarm() async throws {
        let mac = ScanProfile(
            name: "test", concurrency: 8, lanes: 2, chunkSize: 16, writeBehind: 4,
            adaptsToConditions: true)
        let nominal = try await peakInFlight(profile: mac, thermal: .nominal, lowPower: false)
        let warm = try await peakInFlight(profile: mac, thermal: .fair, lowPower: false)
        let lowPower = try await peakInFlight(profile: mac, thermal: .nominal, lowPower: true)
        #expect(nominal == 8)
        #expect(warm == 6)
        #expect(lowPower == 4)

        // A phone does not adapt, and never goes past its width.
        let phone = try await peakInFlight(profile: .phone, thermal: .fair, lowPower: true)
        #expect(phone == 4)
    }

    // MARK: Lanes and the writer

    @Test func laneCountersNeverRunAheadOfTheSavedResults() async throws {
        // Slow previews keep several chunks in flight at once; the counters the store holds must
        // equal the items it holds at every pause, however the lanes interleave.
        let lib = variedLibrary(count: 160)
        lib.previewDelay = .milliseconds(6)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(),
            profile: ScanProfile(
                name: "lanes", concurrency: 8, lanes: 4, chunkSize: 8, writeBehind: 4),
            progressEvery: 1, policy: fast)
        var pauses = 0
        var last: ScanProgress?
        for await p in await scanner.startFullScan() {
            last = p
            if p.state == .running, p.processed >= 20 * (pauses + 1), pauses < 3 {
                pauses += 1
                await scanner.pause(reason: .user)
                let session = try #require(try await store.currentSession())
                // The stored counters are those of the stored chunks: nothing counted twice or ahead,
                // and never more than the items the store holds.
                let chunks = try await store.chunks(job: session.id)
                #expect(
                    session.processedItems == chunks.map(\.doneCount).reduce(0, +),
                    "pause \(pauses)")
                #expect(session.processedItems <= (try await store.items().count))
                #expect(chunks.allSatisfy { $0.state != .running && $0.owner == nil })
                await scanner.resume()
            }
        }
        #expect(pauses == 3)
        #expect(last?.state == .completed)
        #expect(last?.processed == 160)
        #expect(try await store.items().count == 160)
        #expect(try await store.currentSession()?.processedItems == 160)
    }

    @Test func aPauseIsOnlyAcknowledgedOnceEveryLaneAndTheWriterAreDone() async throws {
        let lib = variedLibrary(count: 120)
        lib.previewDelay = .milliseconds(4)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(),
            profile: ScanProfile(
                name: "lanes", concurrency: 6, lanes: 3, chunkSize: 8, writeBehind: 8),
            progressEvery: 1, policy: fast, pauseWaitLimit: .seconds(20))
        var last: ScanProgress?
        var checked = false
        for await p in await scanner.startFullScan() {
            last = p
            if !checked, p.processed >= 24 {
                checked = true
                await scanner.pause(reason: .user)
                #expect(await scanner.pauseAcknowledgements == 1)
                let session = try #require(try await store.currentSession())
                let stored = try await store.items().count
                let chunks = try await store.chunks(job: session.id)
                #expect(session.state == .paused)
                #expect(session.processedItems == chunks.map(\.doneCount).reduce(0, +))
                #expect(chunks.allSatisfy { $0.state != .running })
                // Nothing moves while paused: no lane and no write is still going.
                try await Task.sleep(for: .milliseconds(150))
                #expect(try await store.items().count == stored)
                #expect(try await store.currentSession()?.processedItems == session.processedItems)
                await scanner.resume()
            }
        }
        #expect(checked)
        #expect(last?.state == .completed)
        #expect(try await store.items().count == 120)
    }

    @Test func failedSavesWithSeveralLanesStillLoseNothing() async throws {
        let lib = variedLibrary(count: 120)
        let store = try InMemoryStore.make()
        await store.failNextCheckpointsForTesting(2)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(),
            profile: ScanProfile(
                name: "lanes", concurrency: 6, lanes: 3, chunkSize: 8, writeBehind: 6),
            progressEvery: 1, policy: fast)
        var last: ScanProgress?
        for await p in await scanner.startFullScan() { last = p }
        #expect(last?.state == .completed)
        #expect(last?.processed == 120)
        #expect(last?.total == 120)
        #expect(try await store.items().count == 120)
        let session = try #require(try await store.currentSession())
        #expect(session.processedItems == 120)
    }

    @Test func aScanWithSeveralLanesReclaimsEveryChunkAKilledProcessLeft() async throws {
        let lib = variedLibrary(count: 96)
        let store = try InMemoryStore.make()
        // The process died with three chunks leased, as a three-lane scan leaves them.
        let session = ScanSession(kind: .full, state: .running, totalItems: 96)
        var chunks = ScanPlanner.chunks(jobID: session.id, assetIDs: lib.allIDs, size: 16)
        for k in 0..<3 {
            chunks[k].state = .running
            chunks[k].owner = UUID()
        }
        try await store.createJob(session, chunks: chunks)

        let reclaimed = ScanReclaim.reclaim(chunks, session: session, owner: UUID(), policy: fast)
        #expect(reclaimed.session.crashCount == 1, "one death is one crash")
        #expect(reclaimed.chunks.prefix(3).allSatisfy { $0.isolate && $0.crashes == 1 })
        #expect(reclaimed.chunks.prefix(3).allSatisfy { $0.state == .pending && $0.owner == nil })

        // A new process with several lanes finishes the job; the isolated chunks run one at a time
        // and the rest run wide.
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(),
            profile: ScanProfile(
                name: "lanes", concurrency: 6, lanes: 3, chunkSize: 16, writeBehind: 4),
            policy: fast)
        var last: ScanProgress?
        for await p in await scanner.startFullScan() { last = p }
        #expect(last?.state == .completed)
        #expect(last?.processed == 96)
        #expect(try await store.items().count == 96)
        #expect(try await store.currentSession()?.crashCount == 1)
    }

    // MARK: The results build

    /// Items shaped like a library of look-alikes: clusters of copies with small differences, mixed
    /// aspect ratios, edited copies, flat and missing miniatures.
    func lookAlikes(count: Int) -> [LibraryItem] {
        var rng = SeededRandom(seed: 99)
        var items: [LibraryItem] = []
        var clusterHash: UInt64 = 0
        var clusterThumb: [UInt8] = []
        for i in 0..<count {
            if i % 4 == 0 || clusterThumb.isEmpty {
                // A new cluster: some share a dHash neighbourhood on purpose.
                clusterHash = (rng.next() & 0xFFFF_FFFF_FFFF_0000) | UInt64(i % 7)
                clusterThumb = (0..<1_024).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            }
            var thumb = clusterThumb
            // A copy differs by a little noise; every 9th is a different picture with the same hash.
            let noise = i % 9 == 0 ? 120 : 6
            for k in thumb.indices where rng.unit() < 0.2 {
                let delta = Int(rng.next() % UInt64(noise)) - noise / 2
                thumb[k] = UInt8(max(0, min(255, Int(thumb[k]) + delta)))
            }
            if i % 31 == 0 { thumb = [UInt8](repeating: 17, count: 1_024) }  // flat
            var data = Data(thumb)
            if i % 53 == 0 { data = Data() }  // no miniature
            let hash = clusterHash ^ (i % 5 == 0 ? 1 << UInt64(rng.next() % 6) : 0)
            let wide = i % 11 != 0
            let meta = Make.meta(
                "x\(i)", date: Date(timeIntervalSince1970: 1_600_000_000 + Double(i) * 30),
                width: wide ? 4032 : 3024, height: wide ? 3024 : 4032, favorite: i % 41 == 0,
                edited: i % 13 == 0)
            items.append(Make.item(meta, dHash: hash, thumbprint: data, sharpness: 0.7))
        }
        return items
    }

    @Test func groupingDuplicatesInParallelGivesTheSerialGroups() {
        let items = lookAlikes(count: 3_000)
        let serial = DuplicateGrouping.group(items)
        #expect(serial.count > 20, "the fixture must contain groups")
        for workers in [2, 5, 14] {
            let parallel = DuplicateGrouping.groupInParallel(
                items, extraCheck: nil, workers: workers)
            #expect(
                parallel.map { $0.map(\.assetID) } == serial.map { $0.map(\.assetID) },
                "\(workers) workers")
        }
    }

    @Test func groupingWithAnExtraCheckInParallelGivesTheSerialGroups() {
        let items = lookAlikes(count: 2_400)
        let check: @Sendable (LibraryItem, LibraryItem) -> Bool = { a, b in
            (a.assetID.count + b.assetID.count) % 3 != 0
        }
        let serial = DuplicateGrouping.group(items, extraCheck: check)
        let parallel = DuplicateGrouping.groupInParallel(items, extraCheck: check, workers: 6)
        #expect(parallel.map { $0.map(\.assetID) } == serial.map { $0.map(\.assetID) })
    }

    @Test func theCandidateSlabsCoverEveryPairTheSerialIndexReports() {
        var rng = SeededRandom(seed: 5)
        // Many hashes in a few neighbourhoods: some buckets are large and are cut into several slabs.
        let hashes = (0..<1_500).map { _ in
            (rng.next() & 0xF0F0_0000_0000_0000) | (rng.next() & 0x3F)
        }
        let index = HashIndex(maxDistance: DuplicateThresholds.hashDistance)
        var serial = Set<[Int]>()
        index.forEachCandidatePair(hashes) { serial.insert([$0, $1]) }
        let buckets = index.buckets(hashes)
        let slabs = index.slabs(buckets, targetPairs: 500)
        #expect(slabs.count > 10)
        var parallel = Set<[Int]>()
        var count = 0
        for slab in slabs {
            index.forEachCandidatePair(in: slab, buckets: buckets, hashes: hashes) {
                parallel.insert([$0, $1])
                count += 1
            }
        }
        #expect(parallel == serial)
        #expect(count == serial.count, "each pair is reported once")
    }

    @Test func similarShotsInParallelGiveTheSerialGroups() async throws {
        // Real feature prints from a few dozen distinct pictures, handed out over 2,400 photos shot
        // in runs a few seconds apart, with some photos having none.
        var pool: [Data] = []
        for seed in 1...24 {
            let scene = TestImages.scene(seed: UInt64(seed), width: 96, height: 72)
            pool.append((try? await FeaturePrint.compute(scene)) ?? Data())
        }
        var rng = SeededRandom(seed: 7)
        var items: [LibraryItem] = []
        var thumbs: [[UInt8]] = []
        for _ in 0..<24 {
            var row: [UInt8] = []
            for _ in 0..<1_024 { row.append(UInt8(truncatingIfNeeded: rng.next())) }
            thumbs.append(row)
        }
        for i in 0..<2_400 {
            let which = Int(rng.next() % 24)
            var thumb = thumbs[which]
            for k in thumb.indices where rng.unit() < 0.1 {
                thumb[k] = UInt8(truncatingIfNeeded: rng.next())
            }
            let meta = Make.meta(
                "y\(i)",
                date: Date(
                    timeIntervalSince1970: 1_600_000_000 + Double(i / 4) * 35 + Double(i % 4) * 3),
                burst: i % 17 == 0 ? "B\(i / 17)" : nil)
            items.append(
                Make.item(
                    meta, dHash: UInt64(i), thumbprint: Data(thumb),
                    print: i % 29 == 0 ? Data() : pool[which], sharpness: 0.7))
        }
        let serial = SimilarShotsDetector(parallelism: 1).detect(items: items)
        #expect(serial.count > 20, "the fixture must contain groups")
        for workers in [2, 7] {
            let parallel = SimilarShotsDetector(parallelism: workers, parallelThreshold: 0)
                .detect(items: items)
            #expect(parallel == serial, "\(workers) workers")
        }
    }

    @Test func readingTheStoreInParallelGivesTheSerialRead() async throws {
        let store = try InMemoryStore.make()
        var items: [LibraryItem] = []
        for i in 0..<3_450 {
            let meta = Make.meta("r\(i)", date: Date(timeIntervalSince1970: Double(i)))
            let thumbprint = Data(repeating: UInt8(i % 250), count: 1_024)
            items.append(
                Make.item(
                    meta, dHash: UInt64(i), thumbprint: thumbprint,
                    print: Data("print\(i)".utf8), sharpness: Double(i % 100) / 100))
        }
        try await store.upsert(items)

        await store.setReadParallelism(1)
        let summaries = try await store.itemSummaries()
        let lean = try await store.itemsWithoutFeaturePrints()
        let ids = items.indices.filter { $0 % 3 == 0 }.map { "r\($0)" }
        let prints = try await store.featurePrints(for: ids)

        await store.setReadParallelism(8)
        #expect(try await store.itemSummaries() == summaries)
        #expect(try await store.itemsWithoutFeaturePrints() == lean)
        #expect(try await store.featurePrints(for: ids) == prints)
        #expect(summaries.count == 3_450)
        #expect(prints.count == ids.count)
    }
}
