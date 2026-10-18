import CleanupKit
import Foundation

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func chance(_ p: Double, _ rng: inout SplitMix) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
func expo(_ rng: inout SplitMix) -> Double { -log(max(1e-9, Double.random(in: 0..<1, using: &rng))) }

func flip(_ h: UInt64, bits k: Int, _ rng: inout SplitMix) -> UInt64 {
    var h = h
    var set = Set<Int>()
    while set.count < k { set.insert(Int.random(in: 0..<64, using: &rng)) }
    for b in set { h ^= UInt64(1) << UInt64(b) }
    return h
}

func randomBytes(_ count: Int, _ rng: inout SplitMix) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: count)
    var i = 0
    while i < count {
        var r = rng.next()
        var k = 0
        while k < 8 && i < count { out[i] = UInt8(truncatingIfNeeded: r); r >>= 8; i += 1; k += 1 }
    }
    return out
}

func noisy(_ base: [UInt8], amplitude a: Int, _ rng: inout SplitMix) -> [UInt8] {
    base.map { UInt8(clamping: Int($0) + Int.random(in: -a...a, using: &rng)) }
}

func idString(_ rng: inout SplitMix) -> String {
    let a = rng.next(), b = rng.next()
    return String(
        format: "%08llX-%04llX-%04llX-%04llX-%012llX/L0/001", a >> 32, (a >> 16) & 0xffff,
        a & 0xffff, b >> 48, b & 0xffff_ffff_ffff)
}

struct GenConfig {
    var n: Int
    /// Share of all items that are members of duplicate groups (groups of 2 or 3).
    var dupShare = 0.08
    /// Share of still photos whose dHash is drawn from a few cluster centres (stress).
    var clustered = 0.0
    /// Real Vision feature prints (optional).
    var pool: [Data] = []
    /// Random 4300-byte featurePrint blobs when there is no pool (store sizing).
    var storeBlobs = false
    /// Stress: this many photos get capture dates inside one minute.
    var dense = 0
    var seed: UInt64 = 42
}

func dims(_ kind: ItemKind, _ rng: inout SplitMix) -> (Int, Int) {
    switch kind {
    case .screenshot: return chance(0.5, &rng) ? (1170, 2532) : (1179, 2556)
    case .video: return chance(0.7, &rng) ? (1920, 1080) : (3840, 2160)
    default:
        let u = Double.random(in: 0..<1, using: &rng)
        return u < 0.6 ? (4032, 3024) : u < 0.95 ? (3024, 4032) : (4284, 5712)
    }
}

func makeItem(
    id: String, kind: ItemKind, date: Date, size: (Int, Int), hash: UInt64, thumb: [UInt8],
    fp: Data, burstID: String?, rng: inout SplitMix
) -> LibraryItem {
    let u = Double.random(in: 0..<1, using: &rng)
    let source: AnalysisSource = u < 0.01 ? .notScanned : u < 0.06 ? .cloudPreview : .localPreview
    var duration: Double?
    var bytes: Int64?
    if kind == .video {
        let d = chance(0.05, &rng) ? Double.random(in: 300...1800, using: &rng) : Double.random(in: 2...120, using: &rng)
        duration = d
        bytes = Int64(d * Double.random(in: 1.0e6...2.0e6, using: &rng))
    } else if !chance(0.03, &rng) {
        bytes = Int64.random(in: 1_200_000...5_500_000, using: &rng)
    }
    let still = kind == .photo || kind == .livePhoto
    let albums: [String] = chance(0.08, &rng) ? (chance(0.25, &rng) ? ["Trip", "Family"] : ["Family"]) : []
    let meta = AssetMetadata(
        assetID: id, kind: kind, captureDate: date,
        modificationDate: date.addingTimeInterval(Double.random(in: 0...30, using: &rng)),
        pixelWidth: size.0, pixelHeight: size.1, duration: duration,
        isFavorite: chance(0.02, &rng), hasAdjustments: chance(0.03, &rng),
        isPortrait: still && chance(0.05, &rng), isLongExposure: kind == .livePhoto && chance(0.01, &rng),
        burstID: burstID, albumNames: albums)
    let blurry = chance(0.04, &rng)
    let analysis = Analysis(
        dHash: hash, thumbprint: Data(thumb), featurePrint: fp,
        sharpness: blurry ? Double.random(in: 0.3...0.54, using: &rng) : Double.random(in: 0.6...1.0, using: &rng),
        aestheticsScore: chance(0.7, &rng) ? Double.random(in: -1...1, using: &rng) : nil,
        faceQuality: chance(0.2, &rng) ? Double.random(in: 0...1, using: &rng) : nil)
    return LibraryItem(
        metadata: meta, analysisSource: source, analysis: analysis, byteSize: bytes,
        isSizeEstimated: false, analyzedAt: date.addingTimeInterval(86_400 * 30))
}

func makeItems(_ cfg: GenConfig) -> [LibraryItem] {
    var rng = SplitMix(cfg.seed)
    let n = cfg.n
    let groupCount = Int(Double(n) * cfg.dupShare / 2.2)
    let copyPlan: [Int] = (0..<groupCount).map { _ in chance(0.8, &rng) ? 1 : 2 }
    let copies = copyPlan.reduce(0, +)
    let baseCount = n - copies
    let span = 6.0 * 365 * 86_400
    let start = 1_602_979_200.0
    let sessions = max(1, Int(Double(baseCount) / 10.5))
    let meanGap = span / Double(sessions)
    let centers = (0..<20).map { _ in rng.next() }

    func fingerprint(_ rng: inout SplitMix) -> Data {
        if !cfg.pool.isEmpty { return cfg.pool[Int.random(in: 0..<cfg.pool.count, using: &rng)] }
        return cfg.storeBlobs ? Data(randomBytes(4300, &rng)) : Data()
    }

    var base: [LibraryItem] = []
    base.reserveCapacity(baseCount)
    var t = 0.0
    outer: while base.count < baseCount {
        t += expo(&rng) * meanGap
        let shots = min(40, 1 + Int(expo(&rng) * 5.0))
        for _ in 0..<shots {
            if base.count >= baseCount { break outer }
            t += Double.random(in: 15...240, using: &rng)
            let u = Double.random(in: 0..<1, using: &rng)
            let kind: ItemKind = u < 0.76 ? .photo : u < 0.87 ? .livePhoto : u < 0.94 ? .screenshot : .video
            let still = kind == .photo || kind == .livePhoto
            let size = dims(kind, &rng)
            if still && chance(0.15, &rng) {
                // Burst: 2-10 frames seconds apart.
                let frames = Int.random(in: 2...10, using: &rng)
                let burstID: String? = chance(0.35, &rng) ? idString(&rng) : nil
                let same = chance(0.65, &rng)
                let baseHash = rng.next()
                let baseThumb = randomBytes(1024, &rng)
                let baseFP = fingerprint(&rng)
                for f in 0..<frames {
                    if base.count >= baseCount { break outer }
                    if f > 0 { t += Double.random(in: 0.1...3.0, using: &rng) }
                    let hash = same ? flip(baseHash, bits: Int.random(in: 8...20, using: &rng), &rng) : rng.next()
                    let thumb = same ? noisy(baseThumb, amplitude: 45, &rng) : randomBytes(1024, &rng)
                    let fp = same ? baseFP : fingerprint(&rng)
                    base.append(makeItem(
                        id: idString(&rng), kind: .photo, date: Date(timeIntervalSince1970: start + t),
                        size: size, hash: hash, thumb: thumb, fp: fp, burstID: burstID, rng: &rng))
                }
            } else {
                var hash = rng.next()
                if still && cfg.clustered > 0 && chance(cfg.clustered, &rng) {
                    hash = flip(centers[Int.random(in: 0..<centers.count, using: &rng)], bits: Int.random(in: 0...8, using: &rng), &rng)
                }
                base.append(makeItem(
                    id: idString(&rng), kind: kind, date: Date(timeIntervalSince1970: start + t),
                    size: size, hash: hash, thumb: randomBytes(1024, &rng), fp: fingerprint(&rng),
                    burstID: nil, rng: &rng))
            }
        }
    }

    if cfg.dense > 0 {
        let denseStart = start + span / 2
        var placed = 0
        let stride = max(1, base.count / cfg.dense)
        var i = 0
        while placed < cfg.dense && i < base.count {
            let k = base[i].metadata.kind
            if (k == .photo || k == .livePhoto) && base[i].metadata.burstID == nil {
                base[i].metadata.captureDate = Date(timeIntervalSince1970: denseStart + Double.random(in: 0..<59, using: &rng))
                placed += 1
            }
            i += stride
            if i >= base.count && placed < cfg.dense { i = (i % base.count) + 1 }
        }
    }

    // Duplicate groups: copies of analyzed, non-burst still photos.
    var eligible = base.indices.filter {
        let m = base[$0].metadata
        return (m.kind == .photo || m.kind == .livePhoto) && m.burstID == nil
            && base[$0].analysisSource != .notScanned && base[$0].analysis != nil
    }
    eligible.shuffle(using: &rng)
    var all = base
    for (g, extra) in copyPlan.enumerated() where g < eligible.count {
        let o = base[eligible[g]]
        guard let oa = o.analysis else { continue }
        let thumb = [UInt8](oa.thumbprint)
        for _ in 0..<extra {
            var m = o.metadata
            m.assetID = idString(&rng)
            if chance(0.5, &rng) { m.pixelWidth /= 2; m.pixelHeight /= 2 }
            if chance(0.5, &rng) {
                m.captureDate = Date(timeIntervalSince1970: start + Double.random(in: 0..<span, using: &rng))
            }
            m.isFavorite = false
            let a = Analysis(
                dHash: flip(oa.dHash, bits: Int.random(in: 0...6, using: &rng), &rng),
                thumbprint: Data(noisy(thumb, amplitude: 3, &rng)), featurePrint: oa.featurePrint,
                sharpness: oa.sharpness, aestheticsScore: oa.aestheticsScore, faceQuality: oa.faceQuality)
            let size = o.byteSize.map { Int64(Double($0) * Double.random(in: 0.55...1.0, using: &rng)) }
            all.append(LibraryItem(
                metadata: m, analysisSource: o.analysisSource, analysis: a, byteSize: size,
                isSizeEstimated: false, analyzedAt: o.analyzedAt))
        }
    }
    // The store hands items back in no particular order.
    all.shuffle(using: &rng)
    if all.count > n { all.removeLast(all.count - n) }
    return all
}

/// The order DefaultResultsBuilder uses before detection.
func sortedLikeBuilder(_ items: [LibraryItem]) -> [LibraryItem] {
    items.sorted { a, b in
        let da = a.metadata.captureDate ?? .distantPast
        let db = b.metadata.captureDate ?? .distantPast
        return da != db ? da < db : a.assetID < b.assetID
    }
}

func detectorSet() -> [any CategoryDetector] {
    [
        DuplicatePhotoDetector(), SimilarShotsDetector(), BlurDetector(), ScreenshotsCategory(),
        LargeVideosCategory(),
    ]
}
