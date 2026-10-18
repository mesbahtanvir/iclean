import CoreGraphics
import Darwin
import Foundation

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let t0 = now()
    let r = try body()
    return (r, now() - t0)
}

func timedAsync<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let t0 = now()
    let r = try await body()
    return (r, now() - t0)
}

func currentRSS() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

func peakRSS() -> Double {
    var ru = rusage()
    getrusage(RUSAGE_SELF, &ru)
    return Double(ru.ru_maxrss) / 1_048_576
}

func say(_ s: String) { print(s); fflush(stdout) }

func mem() -> String { String(format: "rss=%.0fMB peak=%.0fMB", currentRSS(), peakRSS()) }

func folderSize(_ url: URL) -> Double {
    var total = 0
    if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
        for case let f as URL in e { total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    }
    return Double(total) / 1_048_576
}

/// A copy of CleanupKit's (internal) HashIndex that also counts inner-loop visits.
struct BenchHashIndex {
    let maxDistance: Int
    private let chunks: [(shift: UInt64, mask: UInt64)]
    init(maxDistance: Int) {
        self.maxDistance = maxDistance
        let count = maxDistance + 1
        var chunks: [(UInt64, UInt64)] = []
        var start = 0
        for i in 0..<count {
            let bits = 64 / count + (i < 64 % count ? 1 : 0)
            let mask: UInt64 = bits == 64 ? .max : (1 << UInt64(bits)) - 1
            chunks.append((UInt64(start), mask))
            start += bits
        }
        self.chunks = chunks
    }
    func candidatePairs(_ hashes: [UInt64]) -> (pairs: [(Int, Int)], visits: Int) {
        var pairs: [(Int, Int)] = []
        var visits = 0
        for (c, chunk) in chunks.enumerated() {
            var buckets: [UInt64: [Int]] = [:]
            for (i, h) in hashes.enumerated() { buckets[(h >> chunk.shift) & chunk.mask, default: []].append(i) }
            for bucket in buckets.values where bucket.count > 1 {
                for a in 0..<bucket.count {
                    for b in (a + 1)..<bucket.count {
                        visits += 1
                        let i = bucket[a], j = bucket[b]
                        if sharesEarlierChunk(hashes[i], hashes[j], before: c) { continue }
                        if (hashes[i] ^ hashes[j]).nonzeroBitCount <= maxDistance { pairs.append((min(i, j), max(i, j))) }
                    }
                }
            }
        }
        return (pairs, visits)
    }
    private func sharesEarlierChunk(_ a: UInt64, _ b: UInt64, before c: Int) -> Bool {
        for k in 0..<c where (a >> chunks[k].shift) & chunks[k].mask == (b >> chunks[k].shift) & chunks[k].mask { return true }
        return false
    }
}

/// Deterministic synthetic 512x384 image (gradient plus random shapes) for Vision.
func synthImage(_ i: Int) -> CGImage {
    var rng = SplitMix(UInt64(i) &* 7919 &+ 12345)
    let w = 512, h = 384
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func c() -> CGFloat { CGFloat(Double.random(in: 0...1, using: &rng)) }
    let grad = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [CGColor(red: c(), green: c(), blue: c(), alpha: 1), CGColor(red: c(), green: c(), blue: c(), alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: Double.random(in: 0...Double(w), using: &rng), y: Double(h)), options: [])
    for _ in 0..<(15 + Int.random(in: 0..<25, using: &rng)) {
        ctx.setFillColor(red: c(), green: c(), blue: c(), alpha: CGFloat(Double.random(in: 0.4...1, using: &rng)))
        let r = CGRect(
            x: Double.random(in: 0...Double(w), using: &rng), y: Double.random(in: 0...Double(h), using: &rng),
            width: Double.random(in: 10...180, using: &rng), height: Double.random(in: 10...180, using: &rng))
        if chance(0.5, &rng) { ctx.fillEllipse(in: r) } else { ctx.fill(r) }
    }
    return ctx.makeImage()!
}

struct Img: @unchecked Sendable { let image: CGImage }
