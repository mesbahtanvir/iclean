import CleanupKit
import CoreGraphics
import Darwin
import Foundation

// Spec 009: the scan with the REAL analyzer. `ScaleBench` proper uses a fake analyzer to measure
// the store and the results build; this file measures where the time of a real scan goes and how
// it scales with the number of cores (Vision, the Neural Engine, the CPU math, the decode).

// MARK: Images

/// Images shaped like the large demo library's (scenes, bursts, copies, blurred photos), but at the
/// 512 px a phone's preview request asks for. Drawn on demand: a library of 30,000 of them would
/// not fit in memory, and drawing one costs about what decoding a thumbnail does.
enum RealRecipe: Sendable {
    case scene(UInt64)
    case copy(UInt64)
    case burst(UInt64, Int)
    case blurred(UInt64)
    case stripes(UInt64)
}

/// The demo library's generator (iclean/App/DemoPhotoLibrary.swift), so `--demo` reproduces the
/// library the app's `-DemoScenario large30k` shows, photo for photo.
struct DemoRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func unit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

enum RealImages {
    static let width = 512
    static let height = 384

    /// The demo library's own pictures: 256 × 192, drawn with its generator.
    static func demoImage(_ recipe: RealRecipe) -> CGImage {
        let w = 256
        let h = 192
        switch recipe {
        case .scene(let seed): return demoScene(seed: seed, width: w, height: h)
        case .copy(let seed): return resized(demoScene(seed: seed, width: w, height: h), 0.5)
        case .burst(let seed, let k):
            return demoBurstFrame(demoScene(seed: seed, width: w, height: h), index: k)
        case .blurred(let seed): return blurred(demoScene(seed: seed, width: w, height: h))
        case .stripes(let seed): return demoStripes(seed: seed, width: 134, height: 291)
        }
    }

    static func demoScene(seed: UInt64, width: Int, height: Int) -> CGImage {
        var rng = DemoRandom(seed: seed)
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<60 {
            ctx.setFillColor(
                CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            let rect = CGRect(
                x: rng.unit() * Double(width), y: rng.unit() * Double(height),
                width: 10 + rng.unit() * Double(width) / 3,
                height: 10 + rng.unit() * Double(height) / 3)
            if rng.unit() > 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
        }
        return ctx.makeImage()!
    }

    static func demoStripes(seed: UInt64, width: Int, height: Int) -> CGImage {
        var rng = DemoRandom(seed: seed)
        let ctx = context(width: width, height: height)
        let band = 8 + Int(rng.unit() * 24)
        for y in stride(from: 0, to: height, by: band) {
            ctx.setFillColor(
                CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: band))
        }
        return ctx.makeImage()!
    }

    static func demoBurstFrame(_ image: CGImage, index: Int) -> CGImage {
        let shifted = context(width: image.width, height: image.height)
        shifted.draw(
            image,
            in: CGRect(x: index * 40, y: index * 40 / 2, width: image.width, height: image.height))
        let moved = shifted.makeImage()!
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(moved, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var rng = DemoRandom(seed: UInt64(500 + index))
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 200 + index * 30, y: 150, width: 140, height: 180))
        return ctx.makeImage()!
    }

    static func image(_ recipe: RealRecipe) -> CGImage {
        switch recipe {
        case .scene(let seed): return scene(seed: seed, width: width, height: height)
        case .copy(let seed): return resized(scene(seed: seed, width: width, height: height), 0.5)
        case .burst(let seed, let k):
            return burstFrame(scene(seed: seed, width: width, height: height), index: k)
        case .blurred(let seed): return blurred(scene(seed: seed, width: width, height: height))
        case .stripes(let seed): return stripes(seed: seed, width: 268, height: 582)
        }
    }

    static func scene(seed: UInt64, width: Int, height: Int) -> CGImage {
        var rng = Rng(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
        let ctx = context(width: width, height: height)
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<60 {
            ctx.setFillColor(
                CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            let rect = CGRect(
                x: rng.unit() * Double(width), y: rng.unit() * Double(height),
                width: 10 + rng.unit() * Double(width) / 3,
                height: 10 + rng.unit() * Double(height) / 3)
            if rng.unit() > 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
        }
        return ctx.makeImage()!
    }

    static func stripes(seed: UInt64, width: Int, height: Int) -> CGImage {
        var rng = Rng(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
        let ctx = context(width: width, height: height)
        let band = 8 + Int(rng.unit() * 24)
        for y in stride(from: 0, to: height, by: band) {
            ctx.setFillColor(
                CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fill(CGRect(x: 0, y: y, width: width, height: band))
        }
        return ctx.makeImage()!
    }

    static func resized(_ image: CGImage, _ scale: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        let ctx = context(width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func blurred(_ image: CGImage) -> CGImage {
        let small = resized(image, 1.0 / 12)
        let ctx = context(width: image.width, height: image.height)
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// One frame of a burst: the camera moved and the subject changed a little.
    static func burstFrame(_ image: CGImage, index: Int) -> CGImage {
        let moved = context(width: image.width, height: image.height)
        moved.draw(
            image,
            in: CGRect(
                x: index * 40, y: index * 20, width: image.width, height: image.height))
        let shifted = moved.makeImage()!
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(shifted, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var rng = Rng(state: UInt64(500 + index) &* 0x9E37_79B9_7F4A_7C15 | 1)
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 200 + index * 30, y: 150, width: 140, height: 180))
        return ctx.makeImage()!
    }

    static func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}

// MARK: Library

/// The large demo library's shape (9% screenshots, 6% videos, bursts of four, copies, blurred
/// photos), with its previews drawn on demand.
final class RealLibrary: PhotoLibrary, @unchecked Sendable {
    let metadata: [AssetMetadata]
    private let byID: [String: AssetMetadata]
    private let recipes: [String: RealRecipe]
    private let demo: Bool
    var previewLatency: Duration = .zero

    init(count: Int, demo: Bool = false) {
        self.demo = demo
        if demo {
            let built = Self.buildDemo(count: count)
            metadata = built.0
            recipes = built.1
            byID = Dictionary(uniqueKeysWithValues: built.0.map { ($0.assetID, $0) })
            return
        }
        var rng = Rng(state: 0x1357_9BDF_2468_ACE1)
        var items: [AssetMetadata] = []
        var recipes: [String: RealRecipe] = [:]
        var clock = 1_600_000_000.0
        var n = 0
        func put(
            _ id: String, kind: ItemKind = .photo, recipe: RealRecipe, at t: Double,
            width: Int = 4032, height: Int = 3024, duration: Double? = nil
        ) {
            let date = Date(timeIntervalSince1970: t)
            items.append(
                AssetMetadata(
                    assetID: id, kind: kind, captureDate: date, modificationDate: date,
                    pixelWidth: width, pixelHeight: height, duration: duration))
            recipes[id] = recipe
        }
        while items.count < count {
            clock += 600 + rng.unit() * 40_000
            let id = "R\(n)"
            let seed = UInt64(n) &+ 1
            switch n % 100 {
            case 0..<9:
                put(
                    id, kind: .screenshot, recipe: .stripes(seed), at: clock, width: 1206,
                    height: 2622)
            case 9..<15:
                put(
                    id, kind: .video, recipe: .scene(seed), at: clock, width: 1920, height: 1080,
                    duration: 5 + rng.unit() * 120)
            case 15..<45:
                for k in 0..<4 where items.count < count {
                    put("\(id)b\(k)", recipe: .burst(seed, k), at: clock + Double(k) * 2.5)
                }
            case 45..<50:
                put(id, recipe: .scene(seed), at: clock)
                if items.count < count {
                    put("\(id)c", recipe: .copy(seed), at: clock + 3_600, width: 2016, height: 1512)
                }
            case 50..<58:
                put(id, recipe: .blurred(seed), at: clock)
            default:
                put(id, recipe: .scene(seed), at: clock)
            }
            n += 1
        }
        metadata = items
        byID = Dictionary(uniqueKeysWithValues: items.map { ($0.assetID, $0) })
        self.recipes = recipes
    }

    func authorizationStatus() -> LibraryAccess { .full }
    func requestAuthorization() async -> LibraryAccess { .full }
    func fetchAllItems() async -> [AssetMetadata] { metadata }
    func fetchItems(withIDs assetIDs: [String]) async -> [AssetMetadata] {
        assetIDs.compactMap { byID[$0] }
    }
    func preview(for assetID: String, maxPixels: Int) async -> PreviewResult {
        if previewLatency > .zero { try? await Task.sleep(for: previewLatency) }
        guard let recipe = recipes[assetID] else { return .unavailable }
        return .local(demo ? RealImages.demoImage(recipe) : RealImages.image(recipe))
    }

    /// `DemoPhotoLibrary.buildLarge`, call for call, so the random stream and the library match.
    private static func buildDemo(count: Int) -> ([AssetMetadata], [String: RealRecipe]) {
        var rng = DemoRandom(seed: 30_000)
        var items: [AssetMetadata] = []
        var recipes: [String: RealRecipe] = [:]
        var clock = 1_600_000_000.0
        var n = 0
        func put(
            _ id: String, kind: ItemKind = .photo, recipe: RealRecipe, at t: Double,
            width: Int = 4032, height: Int = 3024, duration: Double? = nil
        ) {
            let date = Date(timeIntervalSince1970: t)
            items.append(
                AssetMetadata(
                    assetID: id, kind: kind, captureDate: date, modificationDate: date,
                    pixelWidth: width, pixelHeight: height, duration: duration))
            recipes[id] = recipe
        }
        while items.count < count {
            clock += 600 + rng.unit() * 40_000
            let id = "L\(n)"
            let seed = UInt64(n) &+ 1
            switch n % 100 {
            case 0..<9:
                put(
                    id, kind: .screenshot, recipe: .stripes(seed), at: clock, width: 1206,
                    height: 2622)
            case 9..<15:
                let big = rng.unit() < 0.1
                if !big { _ = rng.unit() }
                put(
                    id, kind: .video, recipe: .scene(seed), at: clock, width: 1920, height: 1080,
                    duration: 5 + rng.unit() * 120)
            case 15..<45:
                for k in 0..<4 where items.count < count {
                    put("\(id)b\(k)", recipe: .burst(seed, k), at: clock + Double(k) * 2.5)
                }
            case 45..<50:
                put(id, recipe: .scene(seed), at: clock)
                if items.count < count {
                    put("\(id)c", recipe: .copy(seed), at: clock + 3_600, width: 2016, height: 1512)
                }
            case 50..<58:
                put(id, recipe: .blurred(seed), at: clock)
            default:
                put(id, recipe: .scene(seed), at: clock)
            }
            n += 1
        }
        return (items, recipes)
    }
    func localByteSize(for assetID: String) async -> Int64? { 4_000_000 }
    func remove(_ assetIDs: [String]) async -> RemovalResult {
        RemovalResult(removed: assetIDs, failed: [])
    }
    func changes() -> AsyncStream<LibraryChange> { AsyncStream { _ in } }
}

// MARK: Measuring

/// CPU seconds this process has used (user + system), over all threads.
func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// A fingerprint of a results value that two runs can compare: categories, groups, members in
/// order, keepers, the default selection and the not-scanned count.
func resultsDigest(_ results: CleanupResults) -> String {
    var digest: UInt64 = 1_469_598_103_934_665_603
    func mix(_ s: String) {
        for byte in s.utf8 { digest = (digest ^ UInt64(byte)) &* 1_099_511_628_211 }
        digest = (digest ^ 0xff) &* 1_099_511_628_211
    }
    for c in results.categories {
        mix(c.category.rawValue)
        for g in c.groups {
            mix(g.id)
            g.members.forEach(mix)
            mix("|")
            g.keepers.sorted().forEach(mix)
            mix("#")
            g.dateNotes.keys.sorted().forEach { key in
                mix(key)
                g.dateNotes[key]?.map(\.rawValue).sorted().forEach(mix)
            }
        }
    }
    mix("selection")
    results.defaultSelection.sorted().forEach(mix)
    mix("notScanned\(results.notScannedCount)")
    return String(digest, radix: 16)
}

func summarize(_ results: CleanupResults) -> String {
    results.categories.map { "\($0.category.rawValue)=\($0.groups.count)/\($0.allMembers.count)" }
        .joined(separator: " ")
}

// MARK: Analyzer scaling

/// Runs `DefaultAnalyzer` (or one part of it) over a fixed set of realistic images at several
/// widths and prints images per second and how many cores the process kept busy.
func runAnalyzerScaling(distinct: Int, perRun: Int, widths: [Int], only: String? = nil) async {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    print(
        "Analyzer scaling: \(perRun) analyses per run over \(distinct) distinct 512×384 images, \(cores) cores"
    )
    var images: [CGImage] = []
    var metas: [AssetMetadata] = []
    for i in 0..<distinct {
        let seed = UInt64(i + 1)
        let recipe: RealRecipe =
            i % 8 == 7 ? .blurred(seed) : (i % 8 < 3 ? .burst(seed / 4, i % 4) : .scene(seed))
        images.append(RealImages.image(recipe))
        metas.append(
            AssetMetadata(
                assetID: "a\(i)", kind: .photo, pixelWidth: 4032, pixelHeight: 3024))
    }

    func run(_ name: String, _ body: @escaping @Sendable (CGImage, AssetMetadata) async -> Void)
        async
    {
        if let only, !name.contains(only) { return }
        // Warm up: the first Vision request loads its model.
        for i in 0..<4 { await body(images[i], metas[i]) }
        var baseline: Double?
        for width in widths {
            let cpu0 = cpuSeconds()
            let start = ContinuousClock.now
            let images = images
            let metas = metas
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < perRun else { return }
                    let k = next % images.count
                    next += 1
                    group.addTask(priority: .userInitiated) { await body(images[k], metas[k]) }
                }
                for _ in 0..<width { add() }
                while await group.next() != nil { add() }
            }
            let wall = seconds(ContinuousClock.now - start)
            let cpu = cpuSeconds() - cpu0
            let rate = Double(perRun) / wall
            if baseline == nil { baseline = rate }
            print(
                String(
                    format:
                        "  %-24@ width %2d  %7.1f images/s  x%4.1f  %5.1f ms/image CPU  %4.1f cores busy",
                    name as NSString, width, rate, rate / (baseline ?? rate),
                    cpu / Double(perRun) * 1000, cpu / wall))
            fflush(stdout)
        }
    }

    await run("CPU math (dHash+print+sharp)") { image, _ in
        _ = dHash(image)
        _ = Thumbprint.compute(image)
        _ = Sharpness.score(image)
    }
    await run("FeaturePrint (Vision)") { image, _ in _ = try? await FeaturePrint.compute(image) }
    await run("FaceQuality (Vision)") { image, _ in _ = await FaceQuality.score(image) }
    await run("DefaultAnalyzer") { image, meta in
        _ = try? await DefaultAnalyzer().analyze(image, metadata: meta)
    }
}

// MARK: Real scan

struct RealScanOptions {
    var count = 3_000
    var concurrency = 4
    var chunk = 32
    var latencyMs = 0
    var lanes = 1
    var writeBehind = 0
    /// "mac", "phone" or "" for the explicit numbers above.
    var profile = ""
    /// Keeps the store here after the run, for `--results-profile`.
    var keep: String?
    /// The app's own `large30k` demo library instead of the bench's.
    var demo = false
    /// A what-if, not something the app does: no feature print or face quality for a photo with no
    /// neighbour within the similar-shots window. Results differ; only the time is of interest.
    var deferVision = false
}

/// A full scan with the real analyzer, then the results build the app does after it. Prints the
/// times and a digest of the results.
func runRealScan(_ o: RealScanOptions, sampler: PeakSampler) async throws {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let profile = scanProfile(o)
    print(
        "Real scan: \(o.count) items, profile \(profile.name): concurrency \(profile.concurrency), lanes \(profile.lanes), chunk \(profile.chunkSize), write-behind \(profile.writeBehind), preview latency \(o.latencyMs) ms, \(cores) cores"
    )
    let folder =
        o.keep.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appending(
            path: "iclean-realbench-\(UUID().uuidString)")
    defer { if o.keep == nil { try? FileManager.default.removeItem(at: folder) } }
    let store = try SwiftDataStore.at(folder: folder)
    let library = RealLibrary(count: o.count, demo: o.demo)
    library.previewLatency = .milliseconds(o.latencyMs)
    let scanner = makeScanner(o, library: library, store: store)
    sampler.reset()
    let cpu0 = cpuSeconds()
    let start = ContinuousClock.now
    var last: ScanProgress?
    var nextMark = max(1, o.count / 4)
    for await p in await scanner.startFullScan() {
        last = p
        if p.processed >= nextMark {
            nextMark += max(1, o.count / 4)
            print(
                String(
                    format: "  %6d/%d at %6.1f s  peak %4.0f MB", p.processed, p.total,
                    seconds(ContinuousClock.now - start), sampler.value))
            fflush(stdout)
        }
    }
    let wall = seconds(ContinuousClock.now - start)
    let cpu = cpuSeconds() - cpu0
    let analyzed = o.count
    print(
        String(
            format:
                "scan done (%@): %.1f s  = %.0f items/s  CPU %.1f s (%.1f cores busy)  peak %.0f MB",
            (last?.state.rawValue ?? "?") as NSString, wall, Double(analyzed) / wall, cpu,
            cpu / wall,
            sampler.value))
    fflush(stdout)

    sampler.reset()
    let cpu1 = cpuSeconds()
    let buildStart = ContinuousClock.now
    let builder = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
    let results = try await ResultsLoader(store: store, builder: builder).load()
    let build = seconds(ContinuousClock.now - buildStart)
    print(
        String(
            format: "results build: %.2f s  CPU %.2f s  peak %.0f MB", build, cpuSeconds() - cpu1,
            sampler.value))
    print("  \(summarize(results))")
    print("  digest \(resultsDigest(results))")
    // A fingerprint of what the analysis stored, so two runs over the same library can be compared
    // below the level of the groups: dHash, miniature, sharpness, aesthetics, face and feature print.
    let inputs = try await store.resultInputs()
    var analysisDigest: UInt64 = 1_469_598_103_934_665_603
    func mix(_ bytes: some Sequence<UInt8>) {
        for b in bytes { analysisDigest = (analysisDigest ^ UInt64(b)) &* 1_099_511_628_211 }
    }
    for item in inputs.items.sorted(by: { $0.assetID < $1.assetID }) {
        mix(item.assetID.utf8)
        guard let a = item.analysis else { continue }
        withUnsafeBytes(of: a.dHash) { mix($0) }
        mix(a.thumbprint)
        withUnsafeBytes(of: a.sharpness) { mix($0) }
        withUnsafeBytes(of: a.aestheticsScore ?? -9) { mix($0) }
        withUnsafeBytes(of: a.faceQuality ?? -9) { mix($0) }
    }
    print("  analysis digest (without feature prints) \(String(analysisDigest, radix: 16))")
}

func scanProfile(_ o: RealScanOptions) -> ScanProfile {
    switch o.profile {
    case "mac": return .mac()
    case "phone": return .phone
    default:
        return ScanProfile(
            name: "custom", concurrency: o.concurrency, lanes: o.lanes, chunkSize: o.chunk,
            writeBehind: o.writeBehind)
    }
}

func makeScanner(_ o: RealScanOptions, library: RealLibrary, store: Store) -> ScanPipeline {
    let analyzer: Analyzer =
        o.deferVision ? DeferredVisionAnalyzer(library: library) : DefaultAnalyzer()
    return ScanPipeline(
        library: library, store: store, analyzer: analyzer, profile: scanProfile(o),
        progressEvery: 10, minProgressInterval: .milliseconds(250))
}

/// DefaultAnalyzer without the Vision requests nothing will read: the feature print and the face
/// quality only matter to photos that can be grouped as similar shots, those with another photo
/// within 60 seconds or in the same burst (spec 008, Decision 2). For measuring what that could save.
struct DeferredVisionAnalyzer: Analyzer {
    let needsVision: Set<String>

    init(library: RealLibrary) {
        let photos = library.metadata.filter { $0.kind == .photo || $0.kind == .livePhoto }
            .sorted { ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast) }
        var needs = Set<String>()
        for i in photos.indices {
            guard let d = photos[i].captureDate else { continue }
            let next = i + 1 < photos.count ? photos[i + 1].captureDate : nil
            let before = i > 0 ? photos[i - 1].captureDate : nil
            if next.map({ $0.timeIntervalSince(d) <= 60 }) ?? false
                || before.map({ d.timeIntervalSince($0) <= 60 }) ?? false
                || photos[i].burstID != nil
            {
                needs.insert(photos[i].assetID)
            }
        }
        needsVision = needs
    }

    func analyze(_ image: CGImage, metadata m: AssetMetadata) async throws -> Analysis {
        let hash = dHash(image)
        let wants = needsVision.contains(m.assetID)
        let print = wants ? ((try? await FeaturePrint.compute(image)) ?? Data()) : Data()
        let sharpness = Sharpness.score(image)
        let isPhoto = m.kind == .photo || m.kind == .livePhoto
        let mayBeBlurry =
            isPhoto && !m.isPortrait && !m.isLongExposure && sharpness < 0.55 + 0.05
        let aesthetics = mayBeBlurry ? await Aesthetics.score(image) : nil
        let faces = wants && isPhoto ? await FaceQuality.score(image) : nil
        return Analysis(
            dHash: hash, thumbprint: Thumbprint.compute(image), featurePrint: print,
            sharpness: sharpness, aestheticsScore: aesthetics, faceQuality: faces)
    }
}

// MARK: Vision probe

import CoreML
import Vision

func deviceName(_ d: MLComputeDevice?) -> String {
    switch d {
    case .none: return "default"
    case .some(.cpu): return "CPU"
    case .some(.gpu): return "GPU"
    case .some(.neuralEngine): return "ANE"
    case .some: return "other"
    }
}

/// Which compute devices Vision's requests may use, and what each one costs and returns.
func runVisionProbe() async {
    print("Vision compute devices (legacy VNRequest API)")
    print("  all devices: \(MLComputeDevice.allComputeDevices.map { deviceName($0) })")
    func show(_ name: String, _ request: VNRequest) {
        for stage in [VNComputeStage.main, .postProcessing] {
            let supported = (try? request.supportedComputeStageDevices) ?? [:]
            let list = (supported[stage] ?? []).map { deviceName($0) }.joined(separator: ", ")
            print(
                "  \(name) stage \(stage.rawValue): supports [\(list)], default \(deviceName(request.computeDevice(for: stage)))"
            )
        }
    }
    show("FeaturePrint", VNGenerateImageFeaturePrintRequest())
    show("FaceQuality ", VNDetectFaceCaptureQualityRequest())
    show("Aesthetics  ", VNCalculateImageAestheticsScoresRequest())
}

func visionDevice(_ name: String) -> MLComputeDevice? {
    MLComputeDevice.allComputeDevices.first { deviceName($0) == name }
}

func makeFP(_ name: String) -> VNGenerateImageFeaturePrintRequest {
    let r = VNGenerateImageFeaturePrintRequest()
    if let d = visionDevice(name) { try? r.setComputeDevice(d, for: .main) }
    return r
}

func makeFace(_ name: String) -> VNDetectFaceCaptureQualityRequest {
    let r = VNDetectFaceCaptureQualityRequest()
    if let d = visionDevice(name) { try? r.setComputeDevice(d, for: .main) }
    return r
}

/// Pins each Vision request to one compute device and times it against the framework's own choice,
/// then compares what comes back with the default's output, element by element.
func runVisionDevices(distinct: Int, perRun: Int) async {
    var images: [CGImage] = []
    for i in 0..<distinct {
        images.append(
            RealImages.image(i % 8 == 7 ? .blurred(UInt64(i + 1)) : .scene(UInt64(i + 1))))
    }
    let devices = ["default", "ANE", "GPU", "CPU"]
    func floats(_ o: VNFeaturePrintObservation) -> [Float] {
        o.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    // The reference: the new API as DefaultAnalyzer calls it today.
    var reference: [[Float]] = []
    for image in images.prefix(60) {
        let o = try? await GenerateImageFeaturePrintRequest().perform(on: image)
        reference.append(
            o.map { $0.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } ?? [])
    }
    func timed(_ width: Int, _ body: @escaping @Sendable (CGImage) -> Void) -> (
        rate: Double, cpu: Double
    ) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = width
        let cpu0 = cpuSeconds()
        let start = ContinuousClock.now
        let images = images
        for k in 0..<perRun { queue.addOperation { body(images[k % images.count]) } }
        queue.waitUntilAllOperationsAreFinished()
        let wall = seconds(ContinuousClock.now - start)
        return (Double(perRun) / wall, (cpuSeconds() - cpu0) / Double(perRun) * 1000)
    }
    print("Feature print by device (legacy VNRequest, \(perRun) per run)")
    for name in devices {
        let device = name
        for image in images.prefix(4) {  // warm up
            try? VNImageRequestHandler(cgImage: image).perform([makeFP(name)])
        }
        var maxDiff: Float = 0
        var identical = 0
        for (k, image) in images.prefix(60).enumerated() {
            let r = makeFP(name)
            try? VNImageRequestHandler(cgImage: image).perform([r])
            guard let o = r.results?.first, !reference[k].isEmpty else { continue }
            let f = floats(o)
            if f == reference[k] { identical += 1 }
            for (a, b) in zip(f, reference[k]) { maxDiff = max(maxDiff, abs(a - b)) }
        }
        var line = String(
            format: "  %-8@ identical to new API: %2d/60  max element diff %.2e |",
            name as NSString, identical, maxDiff)
        for width in [1, 4, 8] {
            let m = timed(width) { image in
                try? VNImageRequestHandler(cgImage: image).perform([makeFP(name)])
            }
            line += String(format: "  w%d %6.0f/s %.1fms cpu", width, m.rate, m.cpu)
        }
        print(line)
        fflush(stdout)
    }
    print("Face capture quality by device")
    for name in devices {
        let device = name
        for image in images.prefix(4) {
            try? VNImageRequestHandler(cgImage: image).perform([makeFace(name)])
        }
        var line = "  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) |"
        for width in [1, 4, 8] {
            let m = timed(width) { image in
                try? VNImageRequestHandler(cgImage: image).perform([makeFace(name)])
            }
            line += String(format: "  w%d %6.0f/s %.1fms cpu", width, m.rate, m.cpu)
        }
        print(line)
        fflush(stdout)
    }
    // Both requests on one handler, the way a combined call would make them.
    print("Both requests on one handler (default devices)")
    for width in [1, 4, 8] {
        let m = timed(width) { image in
            let handler = VNImageRequestHandler(cgImage: image)
            try? handler.perform([makeFP("default"), makeFace("default")])
        }
        print(String(format: "  w%d %6.0f images/s %.1f ms cpu", width, m.rate, m.cpu))
    }
}

// MARK: Results build profile

/// Times the results build on a store kept by `--real-scan --keep`: the read, the build, and each
/// detector on its own.
func runResultsProfile(folder: URL, repeats: Int) async throws {
    let work = FileManager.default.temporaryDirectory.appending(
        path: "iclean-realbench-open-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: folder, to: work)
    defer { try? FileManager.default.removeItem(at: work) }
    let store = try SwiftDataStore.at(folder: work)
    let detectors = StandardPipeline.detectors()
    let builder = DefaultResultsBuilder(detectors: detectors)
    var digest = ""
    for run in 1...repeats {
        let cpu0 = cpuSeconds()
        var t = ContinuousClock.now
        let inputs = try await store.resultInputs()
        let read = seconds(ContinuousClock.now - t)
        let readCPU = cpuSeconds() - cpu0
        t = ContinuousClock.now
        let results = builder.buildResults(items: inputs.items, keepMarks: inputs.keepMarks)
        let build = seconds(ContinuousClock.now - t)
        digest = resultsDigest(results)
        print(
            String(
                format:
                    "run %d: read %.2f s (CPU %.2f), build %.2f s (CPU %.2f), total %.2f s  digest %@",
                run, read, readCPU, build, cpuSeconds() - cpu0 - readCPU, read + build, digest))
        if run == 1 {
            let analyzed = inputs.items.filter { $0.analysisSource.hasAnalysis }
            for d in detectors {
                let items = d.needsAnalysis ? analyzed : inputs.items
                t = ContinuousClock.now
                let groups = d.detect(items: items)
                print(
                    String(
                        format: "  %-12@ %.2f s  (%d groups)", d.category.rawValue as NSString,
                        seconds(ContinuousClock.now - t), groups.count))
            }
            print("  \(summarize(results))")
        }
    }
}

/// How the candidate pairs of a kept store are spread: the sizes of the hash buckets, which decide
/// how well the pair confirmation splits across threads and how much a thread must keep in cache.
func runBucketStats(folder: URL) async throws {
    let work = FileManager.default.temporaryDirectory.appending(
        path: "iclean-realbench-open-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: folder, to: work)
    defer { try? FileManager.default.removeItem(at: work) }
    let store = try SwiftDataStore.at(folder: work)
    let items = try await store.itemsWithoutFeaturePrints().filter {
        ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil
    }
    let hashes = items.map { $0.analysis?.dHash ?? 0 }
    // The same split HashIndex makes: 11 chunks of 5 or 6 bits.
    var sizes: [Int] = []
    var totalPairs = 0
    var pairsOfBig = 0
    for c in 0..<11 {
        let bits = 64 / 11 + (c < 64 % 11 ? 1 : 0)
        let shift = (0..<c).reduce(0) { $0 + 64 / 11 + ($1 < 64 % 11 ? 1 : 0) }
        let mask: UInt64 = (1 << UInt64(bits)) - 1
        var counts: [UInt64: Int] = [:]
        for h in hashes { counts[(h >> UInt64(shift)) & mask, default: 0] += 1 }
        for n in counts.values where n > 1 {
            sizes.append(n)
            let pairs = n * (n - 1) / 2
            totalPairs += pairs
            if n > 1_000 { pairsOfBig += pairs }
        }
    }
    sizes.sort(by: >)
    print(
        "photos \(items.count), buckets with 2+ members \(sizes.count), pairs before the distance test \(totalPairs)"
    )
    print("  largest buckets: \(sizes.prefix(12).map(String.init).joined(separator: ", "))")
    print("  pairs in buckets over 1,000 members: \(pairsOfBig)")
}
