import CleanupKit
import CoreGraphics
import Darwin
import Foundation

// MARK: Memory

/// `phys_footprint`: the number the system's memory limit and jetsam use.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true

    init() {
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let now = footprintMB()
                lock.withLock { peak = max(peak, now) }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()
    }

    func reset() { lock.withLock { peak = footprintMB() } }
    var value: Double { lock.withLock { max(peak, footprintMB()) } }
    func stop() { lock.withLock { running = false } }
}

// MARK: Synthetic library

struct Rng {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func unit() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

/// A library shaped like the research's model: 9% screenshots, 6% videos, about 35% of photos
/// within a minute of another, about 4% exact copies.
final class BenchLibrary: PhotoLibrary, @unchecked Sendable {
    let metadata: [AssetMetadata]
    private let byID: [String: AssetMetadata]
    let image: CGImage
    var previewLatency: Duration = .zero

    init(count: Int) {
        var rng = Rng(state: 0x9E37_79B9_7F4A_7C15)
        var items: [AssetMetadata] = []
        var clock = 1_500_000_000.0
        var i = 0
        while items.count < count {
            let roll = rng.unit()
            func make(_ id: String, kind: ItemKind, at t: Double, size: (Int, Int) = (4032, 3024)) {
                let date = Date(timeIntervalSince1970: t)
                items.append(
                    AssetMetadata(
                        assetID: id, kind: kind, captureDate: date, modificationDate: date,
                        pixelWidth: size.0, pixelHeight: size.1,
                        duration: kind == .video ? 5 + rng.unit() * 120 : nil))
            }
            clock += 600 + rng.unit() * 40_000
            if roll < 0.09 {
                make("L\(i)", kind: .screenshot, at: clock, size: (1206, 2622))
            } else if roll < 0.15 {
                make("L\(i)", kind: .video, at: clock, size: (1920, 1080))
            } else if roll < 0.50 {
                // A burst of 2 to 5 shots a few seconds apart.
                for k in 0..<(2 + Int(rng.next() % 4)) {
                    make("L\(i)b\(k)", kind: .photo, at: clock + Double(k) * (1 + rng.unit() * 8))
                }
            } else {
                make("L\(i)", kind: .photo, at: clock)
                if rng.unit() < 0.08 { make("L\(i)d", kind: .photo, at: clock + 3600) }
            }
            i += 1
        }
        metadata = Array(items.prefix(count))
        byID = Dictionary(uniqueKeysWithValues: metadata.map { ($0.assetID, $0) })
        let ctx = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        image = ctx.makeImage()!
    }

    func authorizationStatus() -> LibraryAccess { .full }
    func requestAuthorization() async -> LibraryAccess { .full }
    func fetchAllItems() async -> [AssetMetadata] { metadata }
    func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
        assetIDs.compactMap { byID[$0] }
    }
    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
        if previewLatency > .zero { try? await Task.sleep(for: previewLatency) }
        return .local(image)
    }
    func localByteSize(for assetID: String) async -> Int64? { nil }
    func remove(_ assetIDs: [String]) async -> RemovalResult {
        RemovalResult(removed: assetIDs, failed: [])
    }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

/// Fabricates an analysis of realistic size from the asset id: copies ("…d") share their
/// original's fingerprints, and every feature print is 6 KB.
struct BenchAnalyzer: Analyzer {
    func analyze(_ image: CGImage, metadata m: AssetMetadata) async throws -> Analysis {
        let base = m.assetID.hasSuffix("d") ? String(m.assetID.dropLast()) : m.assetID
        var rng = Rng(state: UInt64(truncatingIfNeeded: base.hashValue) | 1)
        let hash = rng.next()
        let thumb = Data((0..<1024).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        let print = Data((0..<6144).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        return Analysis(
            dHash: hash, thumbprint: thumb, featurePrint: print,
            sharpness: 0.3 + rng.unit() * 0.7, aestheticsScore: rng.unit() - 0.5,
            faceQuality: nil)
    }
}

// MARK: Run

func ms(_ d: Duration) -> Int {
    Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
}

func report(_ name: String, _ start: ContinuousClock.Instant, _ sampler: PeakSampler) {
    let elapsed = ms(ContinuousClock.now - start)
    print(
        String(
            format: "%-34@ %8d ms   peak %6.0f MB   now %6.0f MB", name as NSString, elapsed,
            sampler.value, footprintMB()))
    fflush(stdout)
}

let args = CommandLine.arguments
let count = args.firstIndex(of: "--count").flatMap { Int(args[$0 + 1]) } ?? 30_000
let latencyMs = args.firstIndex(of: "--latency-ms").flatMap { Int(args[$0 + 1]) } ?? 0
let chunk = args.firstIndex(of: "--chunk").flatMap { Int(args[$0 + 1]) } ?? 32
let skipResults = args.contains("--no-results")
/// Leaves out the old `items()` read, so the lean path's memory is not measured on top of it.
let skipFullItems = args.contains("--no-full-items")

func intArg(_ name: String) -> Int? { args.firstIndex(of: name).flatMap { Int(args[$0 + 1]) } }

if args.contains("--analyzer-scaling") {
    // The real analyzer on realistic images, at several widths (spec 009).
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let widths = args.firstIndex(of: "--widths").map {
        args[$0 + 1].split(separator: ",").compactMap { Int($0) }
    } ?? [1, 2, 4, 8, cores, cores * 2]
    await runAnalyzerScaling(
        distinct: intArg("--distinct") ?? 240, perRun: intArg("--per-run") ?? 600, widths: widths,
        only: args.firstIndex(of: "--only").map { args[$0 + 1] })
    exit(0)
}

if args.contains("--vision-probe") {
    await runVisionProbe()
    await runVisionDevices(distinct: 120, perRun: 600)
    exit(0)
}

if let i = args.firstIndex(of: "--levels-profile") {
    try await runLevelsProfile(folder: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

if let i = args.firstIndex(of: "--bucket-stats") {
    try await runBucketStats(folder: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

if let i = args.firstIndex(of: "--results-profile") {
    try await runResultsProfile(
        folder: URL(fileURLWithPath: args[i + 1]), repeats: intArg("--repeats") ?? 3,
        serial: args.contains("--serial"))
    exit(0)
}

if args.contains("--real-scan") {
    // A full scan with the real analyzer and the results build after it (spec 009).
    var o = RealScanOptions()
    o.count = intArg("--count") ?? 3_000
    o.concurrency = intArg("--concurrency") ?? 4
    o.chunk = intArg("--chunk") ?? 32
    o.latencyMs = intArg("--latency-ms") ?? 0
    o.lanes = intArg("--lanes") ?? 1
    o.writeBehind = intArg("--write-behind") ?? 0
    o.profile = args.firstIndex(of: "--profile").map { args[$0 + 1] } ?? ""
    o.keep = args.firstIndex(of: "--keep").map { args[$0 + 1] }
    o.demo = args.contains("--demo")
    o.completeVision = args.contains("--no-defer-vision")
    let sampler = PeakSampler()
    try await runRealScan(o, sampler: sampler)
    sampler.stop()
    exit(0)
}

if args.contains("--stages") {
    await runStageTimings(
        iterations: args.firstIndex(of: "--count").flatMap { Int(args[$0 + 1]) } ?? 200)
    exit(0)
}

if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
    // Builds results from an existing store (a copy of the app's own), to time detection on its data.
    let folder = URL(fileURLWithPath: args[i + 1])
    let work = FileManager.default.temporaryDirectory.appending(
        path: "iclean-scalebench-open-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: folder, to: work)
    defer { try? FileManager.default.removeItem(at: work) }
    let sampler = PeakSampler()
    let store = try SwiftDataStore.at(folder: work)
    let builder = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
    let start = ContinuousClock.now
    let results = try await ResultsLoader(store: store, builder: builder).load()
    report("ResultsLoader.load()", start, sampler)
    for c in results.categories {
        print("  \(c.category.rawValue): \(c.groups.count) groups, \(c.allMembers.count) items")
    }
    // A fingerprint of the result for comparing runs.
    var hasher = Hasher()
    var digest: UInt64 = 1469598103934665603
    for c in results.categories {
        for g in c.groups {
            for byte in (g.id + g.keepers.sorted().joined()).utf8 {
                digest = (digest ^ UInt64(byte)) &* 1099511628211
            }
        }
    }
    _ = hasher
    print("  digest \(String(digest, radix: 16))")
    sampler.stop()
    exit(0)
}

let sampler = PeakSampler()
print("ScaleBench: \(count) items, chunk \(chunk), preview latency \(latencyMs) ms")
let folder = FileManager.default.temporaryDirectory.appending(
    path: "iclean-scalebench-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: folder) }
let store = try SwiftDataStore.at(folder: folder)
let library = BenchLibrary(count: count)
library.previewLatency = .milliseconds(latencyMs)
print(String(format: "baseline footprint %.0f MB", footprintMB()))

func runScan(_ label: String, kind: String) async {
    let scanner = ScanPipeline(
        library: library, store: store, analyzer: BenchAnalyzer(), concurrency: 4,
        chunkSize: chunk, progressEvery: 10)
    sampler.reset()
    let start = ContinuousClock.now
    var events = 0
    var firstEvent: Duration?
    var nextMark = max(1, count / 6)
    var last: ScanProgress?
    for await p in await scanner.startFullScan() {
        events += 1
        if firstEvent == nil { firstEvent = ContinuousClock.now - start }
        last = p
        if p.processed >= nextMark {
            nextMark += max(1, count / 6)
            report("  \(label) \(p.processed)/\(p.total)", start, sampler)
        }
    }
    report("\(label) done (\(last?.state.rawValue ?? "?"))", start, sampler)
    print("  events \(events), first event after \(ms(firstEvent ?? .zero)) ms")
}

// 1. A first full scan of an empty store.
await runScan("full scan", kind: "full")

// 1b. The lean readers the app uses instead of `items()` (spec 008).
do {
    sampler.reset()
    var start = ContinuousClock.now
    let summaries = try await store.itemSummaries()
    report("store.itemSummaries() (\(summaries.count))", start, sampler)
    sampler.reset()
    start = ContinuousClock.now
    let slim = try await store.itemsWithoutFeaturePrints()
    report("store.itemsWithoutFeaturePrints()", start, sampler)
    sampler.reset()
    start = ContinuousClock.now
    let ids = slim.filter { $0.metadata.kind == .photo }.prefix(8_000).map(\.assetID)
    let prints = try await store.featurePrints(for: Array(ids))
    report("store.featurePrints(for: \(ids.count)) -> \(prints.count)", start, sampler)
}

// 2. Everything is stored now: reload results the way the app does after a scan.
if !skipResults && !skipFullItems {
    sampler.reset()
    var start = ContinuousClock.now
    let items = try await store.items()
    report("store.items() (\(items.count))", start, sampler)
    sampler.reset()
    start = ContinuousClock.now
    let builder = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
    let results = builder.buildResults(items: items, keepMarks: [])
    report("buildResults", start, sampler)
    print(
        "  categories: \(results.categories.map { "\($0.category.rawValue)=\($0.groups.count)" })")
}

// 2b. The app's path since spec 007: lean inputs, build, slim, save as the snapshot, restore it.
if !skipResults {
    sampler.reset()
    var start = ContinuousClock.now
    let inputs = try await store.resultInputs()
    report("store.resultInputs() (\(inputs.items.count))", start, sampler)
    sampler.reset()
    start = ContinuousClock.now
    let detectors = StandardPipeline.detectors()
    let slim = DefaultResultsBuilder(detectors: detectors)
        .buildResults(items: inputs.items, keepMarks: inputs.keepMarks).slimmed()
    report("buildResults + slimmed", start, sampler)
    let key = BuilderKey(detectors: detectors.map(\.category), access: .full)
    sampler.reset()
    start = ContinuousClock.now
    let sealed = try StateCodec.seal(
        ResultsSnapshot(
            results: slim, builderKey: key, itemCount: inputs.items.count,
            keepMarkCount: inputs.keepMarks.count))
    report("snapshot seal (\(sealed.count / 1024) KB)", start, sampler)
    sampler.reset()
    start = ContinuousClock.now
    let restored = try StateCodec.open(sealed, as: ResultsSnapshot.self).results()
    report("snapshot open + results() (\(restored.items.count) items)", start, sampler)
}

// 3. A second scan over the finished store: the planning cost of a rescan or a resume.
await runScan("rescan (nothing changed)", kind: "full")

sampler.stop()
