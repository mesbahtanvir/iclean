import CoreGraphics
import Foundation

@testable import CleanupKit

extension LabeledFixtures {
    /// Sets added by later stories, exported for the simulator with the duplicates set.
    static func extraSets() -> [LabeledImage] { blur() + similar() + screenshots() }

    /// 20 bursts of 3–10 shots: the camera moves a little and the subject moves
    /// between frames, like a real burst.
    static func similar() -> [LabeledImage] {
        var out: [LabeledImage] = []
        var rng = SeededRandom(seed: 99)
        var minute = 200_000.0
        for g in 0..<20 {
            let base = TestImages.scene(seed: UInt64(30_000 + g))
            let count = 3 + Int(rng.unit() * 8)
            for i in 0..<count {
                let frame = TestImages.withSubject(
                    TestImages.shifted(base, dx: i * 8, dy: i * 3), seed: UInt64(g), step: i)
                out.append(LabeledImage(
                    file: "similar/burst\(g)-\(i).jpg", image: frame, minutes: minute + Double(i) * 0.05,
                    similarGroup: "burst\(g)", favorite: g % 5 == 0 && i == count - 1))
            }
            minute += 60
        }
        return out
    }

    static func screenshots() -> [LabeledImage] {
        (0..<30).map { i in
            LabeledImage(
                file: "screenshots/shot\(i).png", image: TestImages.stripes(seed: UInt64(40_000 + i), width: 402, height: 874),
                kind: .screenshot, minutes: 300_000 + Double(i) * 30)
        }
    }
}
