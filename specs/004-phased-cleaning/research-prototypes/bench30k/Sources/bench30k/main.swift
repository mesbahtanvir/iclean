import CleanupKit
import CoreGraphics
import Foundation

var opts: [String: String] = [:]
let args = Array(CommandLine.arguments.dropFirst())
let caseName = args.first ?? "help"
for a in args.dropFirst() {
    let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { opts[parts[0]] = parts[1] }
}
let n = Int(opts["n"] ?? "30000") ?? 30000

func loadPool(_ path: String) -> [Data] {
    guard let d = FileManager.default.contents(atPath: path) else { return [] }
    var out: [Data] = []
    var i = d.startIndex
    while i < d.endIndex {
        let len = d[i..<i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        i += 4
        out.append(d[i..<i + Int(len)])
        i += Int(len)
    }
    return out
}

func config() -> GenConfig {
    var cfg = GenConfig(n: n)
    cfg.clustered = Double(opts["clustered"] ?? "0") ?? 0
    cfg.dense = Int(opts["dense"] ?? "0") ?? 0
    cfg.storeBlobs = opts["blobs"] == "1"
    if let p = opts["pool"] { cfg.pool = loadPool(p) }
    return cfg
}

func generate() -> [LibraryItem] {
    let (items, t) = timed { makeItems(config()) }
    let dates = items.compactMap(\.metadata.captureDate)
    let years = (dates.max()!.timeIntervalSince(dates.min()!)) / (365 * 86_400)
    say(String(format: "GEN n=%d time=%.2fs span=%.1fy %@", items.count, t, years, mem()))
    return items
}

func counts(_ r: CleanupResults) -> String {
    r.categories.map { "\($0.category.rawValue)=\($0.groups.count)g/\($0.allMembers.count)m" }.joined(separator: " ")
}

switch caseName {
case "build":
    let items = generate()
    let builder = DefaultResultsBuilder(detectors: detectorSet())
    for run in 1...(Int(opts["runs"] ?? "2") ?? 2) {
        let before = currentRSS()
        let (res, dt) = timed { builder.buildResults(items: items, keepMarks: []) }
        say(String(format: "BUILD n=%d run=%d wall=%.3fs rssBefore=%.0fMB rssAfter=%.0fMB peak=%.0fMB | %@", n, run, dt, before, currentRSS(), peakRSS(), counts(res)))
    }

case "detectors":
    let items = sortedLikeBuilder(generate())
    for d in detectorSet() {
        let before = currentRSS()
        let (g, dt) = timed { d.detect(items: items) }
        say(String(format: "DETECT n=%d %@ wall=%.3fs groups=%d rssBefore=%.0fMB peak=%.0fMB", n, d.category.rawValue, dt, g.count, before, peakRSS()))
    }

case "dup":
    let items = sortedLikeBuilder(generate())
    let photos = items.filter { ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil }
    let hashes = photos.map { $0.analysis!.dHash }
    let ((pairs, visits), ti) = timed { BenchHashIndex(maxDistance: 10).candidatePairs(hashes) }
    var passCheap = 0
    for (i, j) in pairs {
        let a = photos[i].metadata, b = photos[j].metadata
        guard a.hasAdjustments == b.hasAdjustments, a.aspectRatio > 0, b.aspectRatio > 0 else { continue }
        if abs(a.aspectRatio - b.aspectRatio) / max(a.aspectRatio, b.aspectRatio) <= 0.01 { passCheap += 1 }
    }
    say(String(format: "DUPINDEX n=%d photos=%d indexWall=%.3fs innerVisits=%d candidatePairs=%d passCheapFilters(=thumbprint evaluations)=%d", n, photos.count, ti, visits, pairs.count, passCheap))
    let det = DuplicatePhotoDetector()
    let before = currentRSS()
    let (g, dt) = timed { det.detect(items: items) }
    say(String(format: "DUPDETECT n=%d clustered=%@ wall=%.3fs groups=%d members=%d rssBefore=%.0fMB peak=%.0fMB", n, opts["clustered"] ?? "0", dt, g.count, g.reduce(0) { $0 + $1.members.count }, before, peakRSS()))

case "similar":
    let items = sortedLikeBuilder(generate())
    let photos = items.filter { ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil }
    var windowPairs = 0
    for i in photos.indices {
        guard let di = photos[i].metadata.captureDate else { continue }
        var j = i + 1
        while j < photos.count, let dj = photos[j].metadata.captureDate, dj.timeIntervalSince(di) <= 60 { windowPairs += 1; j += 1 }
    }
    let det = SimilarShotsDetector()
    let before = currentRSS()
    let (g, dt) = timed { det.detect(items: items) }
    say(String(format: "SIMILAR n=%d dense=%@ fpPool=%d windowPairs=%d wall=%.3fs groups=%d members=%d rssBefore=%.0fMB rssAfter=%.0fMB peak=%.0fMB", n, opts["dense"] ?? "0", config().pool.count, windowPairs, dt, g.count, g.reduce(0) { $0 + $1.members.count }, before, currentRSS(), peakRSS()))

case "pair":
    let items = generate().filter { $0.analysis != nil }
    var rng = SplitMix(7)
    let m = 20_000
    let idx = (0..<m).map { _ in (Int.random(in: 0..<items.count, using: &rng), Int.random(in: 0..<items.count, using: &rng)) }
    var sink = 0.0
    let (_, t1) = timed { for (i, j) in idx { sink += Thumbprint.detailSimilarity(items[i].analysis!.thumbprint, items[j].analysis!.thumbprint) } }
    let (_, t2) = timed { for (i, j) in idx { sink += Thumbprint.meanAbsoluteDifference(items[i].analysis!.thumbprint, items[j].analysis!.thumbprint) } }
    let (_, t3) = timed { for (i, j) in idx { sink += Thumbprint.similarity(items[i].analysis!.thumbprint, items[j].analysis!.thumbprint) } }
    say(String(format: "PAIR per-pair detailSimilarity=%.1fus meanAbsDiff=%.1fus similarity=%.1fus (sink %.1f)", t1 / Double(m) * 1e6, t2 / Double(m) * 1e6, t3 / Double(m) * 1e6, sink))

case "planner":
    // Verbatim copy of ScanPlanner.plan (internal in CleanupKit).
    struct PlanOut { var gone: Set<String>; var refreshed: [LibraryItem]; var toAnalyze: [AssetMetadata] }
    func plan(library: [AssetMetadata], stored: [LibraryItem], kind: ScanKind, policy: ScanRetryPolicy) -> PlanOut {
        let storedByID = Dictionary(stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(library.map(\.assetID))
        var refreshed: [LibraryItem] = []
        var toAnalyze: [AssetMetadata] = []
        for m in library {
            guard let existing = storedByID[m.assetID], existing.metadata.modificationDate == m.modificationDate else { toAnalyze.append(m); continue }
            if kind == .full, existing.analysisSource == .notScanned, existing.scanAttempts < policy.crossScanAttempts { toAnalyze.append(m); continue }
            if existing.metadata != m { var u = existing; u.metadata = m; refreshed.append(u) }
        }
        return PlanOut(gone: Set(storedByID.keys).subtracting(currentIDs), refreshed: refreshed, toAnalyze: toAnalyze)
    }
    var cfg = config(); cfg.storeBlobs = true
    let stored = makeItems(cfg)
    say("GEN stored n=\(stored.count) \(mem())")
    var rng = SplitMix(99)
    var library = stored.map(\.metadata)
    // 1% removed from library, 2% edited since the scan, 1% new, 3% metadata-only change (favorite).
    library.shuffle(using: &rng)
    library.removeLast(library.count / 100)
    for i in library.indices {
        let u = Double.random(in: 0..<1, using: &rng)
        if u < 0.02 { library[i].modificationDate = Date().addingTimeInterval(1000) } else if u < 0.05 { library[i].isFavorite.toggle() }
    }
    for _ in 0..<(library.count / 100) { var m = library[0]; m.assetID = idString(&rng); library.append(m) }
    library.shuffle(using: &rng)
    for kind in [ScanKind.quickCheck, .full] {
        for run in 1...3 {
            let before = currentRSS()
            let (p, dt) = timed { plan(library: library, stored: stored, kind: kind, policy: .default) }
            say(String(format: "PLAN n=%d kind=%@ run=%d wall=%.4fs gone=%d refreshed=%d toAnalyze=%d rssBefore=%.0fMB peak=%.0fMB", stored.count, kind.rawValue, run, dt, p.gone.count, p.refreshed.count, p.toAnalyze.count, before, peakRSS()))
        }
    }

case "store-write":
    let folder = URL(fileURLWithPath: opts["folder"]!)
    try? FileManager.default.removeItem(at: folder)
    var cfg = config(); if cfg.pool.isEmpty { cfg.storeBlobs = true }
    let items = makeItems(cfg)
    say("GEN n=\(items.count) avgFP=\(items.reduce(0) { $0 + ($1.analysis?.featurePrint.count ?? 0) } / items.count)B \(mem())")
    let mode = opts["mode"] ?? "upsert"
    let store = try SwiftDataStore.at(folder: folder)
    let jobID = UUID()
    var session = ScanSession(id: jobID, kind: .full, state: .running, totalItems: items.count)
    var chunkTimes: [Double] = []
    let slices = stride(from: 0, to: items.count, by: 32).map { Array(items[$0..<min($0 + 32, items.count)]) }
    let t0 = now()
    if mode == "checkpoint" {
        let chunks = slices.enumerated().map { ScanChunk(jobID: jobID, sequence: $0.offset, assetIDs: $0.element.map(\.assetID)) }
        let (_, tc) = try await timedAsync { try await store.createJob(session, chunks: chunks) }
        say(String(format: "STORE createJob(%d chunks) %.3fs", chunks.count, tc))
        for (k, slice) in slices.enumerated() {
            var chunk = chunks[k]
            chunk.state = .done
            chunk.doneMask = slice.count == 64 ? .max : (UInt64(1) << UInt64(slice.count)) - 1
            session.processedItems += slice.count
            let (_, dt) = try await timedAsync { try await store.checkpoint(items: slice, chunk: chunk, session: session) }
            chunkTimes.append(dt)
        }
    } else {
        for slice in slices {
            let (_, dt) = try await timedAsync { try await store.upsert(slice) }
            chunkTimes.append(dt)
        }
    }
    let total = now() - t0
    func mean(_ a: ArraySlice<Double>) -> Double { a.reduce(0, +) / Double(a.count) * 1000 }
    let sorted = chunkTimes.sorted()
    say(String(format: "STOREWRITE mode=%@ n=%d chunks=%d total=%.2fs meanChunk=%.1fms first100=%.1fms last100=%.1fms p99=%.1fms max=%.1fms disk=%.0fMB %@", mode, items.count, slices.count, total, mean(chunkTimes[...]), mean(chunkTimes.prefix(100)), mean(chunkTimes.suffix(100)), sorted[Int(Double(sorted.count) * 0.99)] * 1000, sorted.last! * 1000, folderSize(folder), mem()))

case "store-read":
    let folder = URL(fileURLWithPath: opts["folder"]!)
    say("START \(mem()) disk=\(String(format: "%.0f", folderSize(folder)))MB")
    let store = try SwiftDataStore.at(folder: folder)
    var loaded: [LibraryItem] = []
    for run in 1...2 {
        let before = currentRSS()
        let (items, dt) = try await timedAsync { try await store.items() }
        say(String(format: "STOREREAD run=%d n=%d wall=%.3fs rssBefore=%.0fMB rssAfter=%.0fMB peak=%.0fMB", run, items.count, dt, before, currentRSS(), peakRSS()))
        loaded = items
    }
    let builder = DefaultResultsBuilder(detectors: detectorSet())
    let before = currentRSS()
    let (res, dt) = timed { builder.buildResults(items: loaded, keepMarks: []) }
    say(String(format: "LAUNCHBUILD n=%d wall=%.3fs rssBefore=%.0fMB rssAfter=%.0fMB peak=%.0fMB | %@", loaded.count, dt, before, currentRSS(), peakRSS(), counts(res)))

case "pool":
    let count = Int(opts["count"] ?? "1000") ?? 1000
    var datas = [Data?](repeating: nil, count: count)
    let t0 = now()
    await withTaskGroup(of: (Int, Data?).self) { group in
        var next = 0
        func add(_ i: Int) { let img = Img(image: synthImage(i)); group.addTask { (i, try? await FeaturePrint.compute(img.image)) } }
        while next < min(4, count) { add(next); next += 1 }
        while let (i, d) = await group.next() { datas[i] = d; if next < count { add(next); next += 1 } }
    }
    let good = datas.compactMap { $0 }
    let total = now() - t0
    var blob = Data()
    for d in good { var len = UInt32(d.count); blob.append(Data(bytes: &len, count: 4)); blob.append(d) }
    FileManager.default.createFile(atPath: opts["out"]!, contents: blob)
    say(String(format: "POOL made=%d/%d avgBytes=%d wall=%.1fs (%.1f prints/s, 4-wide incl. image synthesis)", good.count, count, good.reduce(0) { $0 + $1.count } / max(1, good.count), total, Double(count) / total))
    if good.count >= 2 {
        let (dd, td) = timed { (0..<2000).map { FeaturePrint.distance(good[$0 % good.count], good[($0 * 7 + 1) % good.count]) } }
        say(String(format: "POOL decode+distance (uncached) %.0fus/pair; sample distance %.3f", td / 2000 * 1e6, dd[0]))
        let (_, tdec) = timed { for i in 0..<500 { _ = FeaturePrint.decode(good[i % good.count]) } }
        say(String(format: "POOL JSON decode only %.0fus/print", tdec / 500 * 1e6))
    }

case "analyze":
    let count = Int(opts["count"] ?? "160") ?? 160
    let images = (0..<count).map { Img(image: synthImage($0)) }
    let analyzer = DefaultAnalyzer()
    let meta = AssetMetadata(assetID: "x", kind: .photo, pixelWidth: 512, pixelHeight: 384)
    _ = try? await analyzer.analyze(images[0].image, metadata: meta)
    let seqN = min(40, count)
    let (_, ts) = await timedAsync { for i in 0..<seqN { _ = try? await analyzer.analyze(images[i].image, metadata: meta) } }
    say(String(format: "ANALYZE sequential %d items in %.2fs = %.1f items/s (%.0f ms/item)", seqN, ts, Double(seqN) / ts, ts / Double(seqN) * 1000))
    for width in [4, 8] {
        let (_, tw) = await timedAsync {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add(_ i: Int) { let img = images[i]; group.addTask { _ = try? await analyzer.analyze(img.image, metadata: meta) } }
                while next < min(width, count) { add(next); next += 1 }
                while await group.next() != nil { if next < count { add(next); next += 1 } }
            }
        }
        say(String(format: "ANALYZE %d-wide %d items in %.2fs = %.1f items/s", width, count, tw, Double(count) / tw))
    }
    let (_, tf) = await timedAsync { for i in 0..<seqN { _ = try? await FeaturePrint.compute(images[i].image) } }
    say(String(format: "ANALYZE feature print alone sequential %.0f ms/item", tf / Double(seqN) * 1000))
    let (_, tt) = timed { for i in 0..<count { _ = Thumbprint.compute(images[i].image) } }
    say(String(format: "ANALYZE thumbprint alone %.2f ms/item", tt / Double(count) * 1000))

default:
    say("cases: build detectors dup similar pair planner store-write store-read pool analyze")
}
