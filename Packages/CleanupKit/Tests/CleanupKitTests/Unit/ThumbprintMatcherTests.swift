import Foundation
import Testing

@testable import CleanupKit

/// The cheap way of confirming a duplicate candidate (spec 008) must give the answer the plain
/// definition gives, for every pair.
@Suite struct ThumbprintMatcherTests {
    func reference(_ a: Data, _ b: Data) -> Bool {
        Thumbprint.detailSimilarity(a, b) >= DuplicateThresholds.thumbprint
            && Thumbprint.meanAbsoluteDifference(a, b) <= DuplicateThresholds.brightness
    }

    /// Miniatures of every kind: flat, noisy, smooth, copies with noise, brighter copies and
    /// broken ones.
    func samples() -> [Data] {
        var rng = SeededRandom(seed: 7)
        let side = Thumbprint.side
        func miniature(_ f: (Int, Int) -> Double) -> Data {
            Data((0..<side * side).map { UInt8(max(0, min(255, f($0 % side, $0 / side)))) })
        }
        var out: [Data] = []
        for level in stride(from: 0, through: 255, by: 51) {
            out.append(miniature { _, _ in Double(level) })
        }
        out.append(miniature { _, _ in 10 })
        out.append(miniature { _, _ in 12 })
        for seed in 0..<12 {
            var r = SeededRandom(seed: UInt64(seed))
            let base = (0..<side * side).map { _ in r.unit() * 255 }
            out.append(Data(base.map { UInt8($0) }))
            // Copies of it: a little noise, brighter, a lot of noise.
            for (noise, shift) in [(3.0, 0.0), (6.0, 8.0), (40.0, 0.0), (3.0, 30.0)] {
                out.append(
                    Data(
                        base.map {
                            UInt8(max(0, min(255, $0 + (rng.unit() - 0.5) * noise + shift)))
                        }))
            }
            // A gradient with a bump: smooth content.
            out.append(miniature { x, y in Double(x * 6 + y * 2) + Double(seed) * 3 })
        }
        out.append(Data())
        out.append(Data(repeating: 1, count: 100))
        return out
    }

    @Test func theCheapCheckGivesTheSameAnswerForEveryPair() {
        let all = samples()
        var matcher = ThumbprintMatcher(all)
        var agreed = 0
        var matched = 0
        for i in all.indices {
            for j in all.indices where i < j {
                let expected = reference(all[i], all[j])
                #expect(matcher.confirms(i, j) == expected, "pair \(i) \(j)")
                agreed += 1
                if expected { matched += 1 }
            }
        }
        #expect(agreed > 2_000)
        // The sample set has matches and non-matches, so the test means something.
        #expect(matched > 20 && matched < agreed / 2)
    }

    @Test func aSmallCacheStillGivesTheSameAnswers() {
        // Pairs revisit photos after the cache was emptied.
        let all = samples()
        var matcher = ThumbprintMatcher(all, cacheLimit: 5)
        for _ in 0..<3 {
            for i in all.indices.reversed() {
                for j in all.indices where j < i {
                    #expect(matcher.confirms(j, i) == reference(all[j], all[i]))
                }
            }
        }
    }
}
