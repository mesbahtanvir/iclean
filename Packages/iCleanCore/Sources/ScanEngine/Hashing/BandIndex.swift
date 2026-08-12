import Foundation

/// In-memory multi-index hashing for near-dupe candidate search
/// (SCAN_PIPELINE.md §6.2). Each 64-bit pHash splits into 8 bands of 8 bits;
/// by pigeonhole, any pair within Hamming distance ≤ 7 shares at least one
/// identical band. Rebuilt at launch from the persisted phash column —
/// never persisted itself.
///
/// ≤ 7 is the candidate SEARCH RADIUS, not a verdict: callers apply their own
/// per-action thresholds on top.
public struct BandIndex: Sendable {
    /// Key = band position (3 bits) << 8 | band value (8 bits).
    private var buckets: [UInt16: [String]] = [:]
    private var hashes: [String: UInt64] = [:]

    public init() {}

    public init(hashes: [(id: String, phash: UInt64)]) {
        for entry in hashes { insert(id: entry.id, phash: entry.phash) }
    }

    public mutating func insert(id: String, phash: UInt64) {
        if let existing = hashes[id] {
            guard existing != phash else { return }
            remove(id: id)
        }
        hashes[id] = phash
        for band in 0..<8 {
            buckets[Self.key(band: band, value: Self.bandValue(phash, band: band)), default: []].append(id)
        }
    }

    public mutating func remove(id: String) {
        guard let phash = hashes.removeValue(forKey: id) else { return }
        for band in 0..<8 {
            let key = Self.key(band: band, value: Self.bandValue(phash, band: band))
            buckets[key]?.removeAll { $0 == id }
            if buckets[key]?.isEmpty == true { buckets.removeValue(forKey: key) }
        }
    }

    public var count: Int { hashes.count }

    public func hash(for id: String) -> UInt64? { hashes[id] }

    /// All ids within Hamming distance ≤ radius of `phash` (radius capped at 7 —
    /// the index's recall guarantee). Excludes `excluding`.
    public func candidates(near phash: UInt64, radius: Int, excluding: String? = nil) -> [String] {
        precondition(radius <= 7, "band index guarantees recall only up to Hamming 7")
        var seen = Set<String>()
        var out: [String] = []
        for band in 0..<8 {
            let key = Self.key(band: band, value: Self.bandValue(phash, band: band))
            guard let bucket = buckets[key] else { continue }
            for id in bucket {
                guard id != excluding, !seen.contains(id) else { continue }
                seen.insert(id)
                if let other = hashes[id], (other ^ phash).nonzeroBitCount <= radius {
                    out.append(id)
                }
            }
        }
        out.sort() // determinism (SCAN_PIPELINE.md §13.3)
        return out
    }

    private static func bandValue(_ hash: UInt64, band: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: hash >> (UInt64(band) * 8))
    }

    private static func key(band: Int, value: UInt8) -> UInt16 {
        UInt16(band) << 8 | UInt16(value)
    }
}
