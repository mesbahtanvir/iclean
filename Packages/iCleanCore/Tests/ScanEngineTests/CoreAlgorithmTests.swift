import XCTest
@testable import ScanEngine
import PhotoGateway
import FixtureKit

final class HashingTests: XCTestCase {
    func testIdenticalImagesHashIdentically() {
        let image = FixturePixels.noise(seed: 42)
        XCTAssertEqual(PerceptualHash.pHash64(image), PerceptualHash.pHash64(image))
        XCTAssertEqual(PerceptualHash.dHash64(image), PerceptualHash.dHash64(image))
    }

    func testPerturbedCopyStaysNear() {
        let original = FixturePixels.noise(seed: 7)
        let copy = FixturePixels.perturbed(original, flips: 20, seed: 99)
        let distance = PerceptualHash.hamming64(
            PerceptualHash.pHash64(original), PerceptualHash.pHash64(copy)
        )
        XCTAssertLessThanOrEqual(distance, 7, "light perturbation must stay within the candidate radius")
    }

    func testDifferentImagesHashFar() {
        let a = FixturePixels.noise(seed: 1)
        let b = FixturePixels.noise(seed: 2)
        let distance = PerceptualHash.hamming64(PerceptualHash.pHash64(a), PerceptualHash.pHash64(b))
        XCTAssertGreaterThan(distance, 10, "independent noise images must not collide")
    }
}

final class BandIndexTests: XCTestCase {
    /// The pigeonhole guarantee: every pair within Hamming ≤ 7 must be found.
    func testPigeonholeRecall() {
        var index = BandIndex()
        var rng = SystemRandomNumberGenerator()
        let base = UInt64.random(in: .min ... .max, using: &rng)
        index.insert(id: "base", phash: base)

        for radius in 0...7 {
            var mutated = base
            var flipped = Set<Int>()
            while flipped.count < radius {
                let bit = Int.random(in: 0..<64, using: &rng)
                guard !flipped.contains(bit) else { continue }
                flipped.insert(bit)
                mutated ^= 1 << UInt64(bit)
            }
            let hits = index.candidates(near: mutated, radius: 7)
            XCTAssertTrue(hits.contains("base"), "pair at distance \(radius) must be recalled")
        }
    }

    func testRadiusVerification() {
        var index = BandIndex()
        let base: UInt64 = 0
        index.insert(id: "zero", phash: base)
        // 12 bits flipped — beyond radius 7, must NOT be returned even though
        // some bands may still match.
        var far: UInt64 = 0
        for bit in 0..<12 { far ^= 1 << UInt64(bit * 5) }
        XCTAssertFalse(index.candidates(near: far, radius: 7).contains("zero"))
    }

    func testRemove() {
        var index = BandIndex()
        index.insert(id: "a", phash: 0xDEAD_BEEF)
        index.remove(id: "a")
        XCTAssertTrue(index.candidates(near: 0xDEAD_BEEF, radius: 0).isEmpty)
        XCTAssertEqual(index.count, 0)
    }
}

final class PixelMathTests: XCTestCase {
    func testBlurLadderMonotonicity() {
        let sharp = FixturePixels.noise(seed: 5)
        let soft = FixturePixels.blurred(sharp, passes: 2)
        let mush = FixturePixels.blurred(sharp, passes: 8)
        let sharpVar = PixelMath.laplacianVariance(sharp)
        let softVar = PixelMath.laplacianVariance(soft)
        let mushVar = PixelMath.laplacianVariance(mush)
        XCTAssertGreaterThan(sharpVar, softVar)
        XCTAssertGreaterThan(softVar, mushVar)
    }

    func testBlankFrameDetection() {
        let blank = FixturePixels.flat(value: 128)
        XCTAssertTrue(JunkDetectors.isBlankFrame(pixelVariance: PixelMath.pixelVariance(blank)))
        let noise = FixturePixels.noise(seed: 3)
        XCTAssertFalse(JunkDetectors.isBlankFrame(pixelVariance: PixelMath.pixelVariance(noise)))
    }

    func testDarkFrame() {
        let dark = FixturePixels.flat(value: 4)
        XCTAssertLessThan(PixelMath.meanLuminance(dark), 24)
        XCTAssertGreaterThan(PixelMath.bottomConcentration(dark), 0.85)
    }
}

final class SessionizerTests: XCTestCase {
    private func input(_ id: String, minutesFromEpoch: Double, bucket: LocationBucket? = nil) -> Sessionizer.Input {
        Sessionizer.Input(
            id: id,
            date: Date(timeIntervalSince1970: minutesFromEpoch * 60),
            bucket: bucket
        )
    }

    func testGapSplitting() {
        let drafts = Sessionizer.sessionize([
            input("a", minutesFromEpoch: 0),
            input("b", minutesFromEpoch: 5),
            input("c", minutesFromEpoch: 30), // > 10 min gap → new session
        ])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].memberIds, ["a", "b"])
        XCTAssertEqual(drafts[1].memberIds, ["c"])
    }

    func testAdjacentBucketDoesNotSplit() {
        let drafts = Sessionizer.sessionize([
            input("a", minutesFromEpoch: 0, bucket: LocationBucket(lat: 10, lon: 10)),
            input("b", minutesFromEpoch: 2, bucket: LocationBucket(lat: 11, lon: 10)), // Chebyshev 1
            input("c", minutesFromEpoch: 4, bucket: LocationBucket(lat: 14, lon: 10)), // Chebyshev 3 → split
        ])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].memberIds, ["a", "b"])
    }

    func testMissingLocationInheritsRunningBucket() {
        let drafts = Sessionizer.sessionize([
            input("a", minutesFromEpoch: 0, bucket: LocationBucket(lat: 0, lon: 0)),
            input("b", minutesFromEpoch: 1, bucket: nil), // never triggers a jump
            input("c", minutesFromEpoch: 2, bucket: LocationBucket(lat: 0, lon: 0)),
        ])
        XCTAssertEqual(drafts.count, 1)
    }

    func testUndatedSessionIsSeparateAndFlagged() {
        let drafts = Sessionizer.sessionize([
            input("a", minutesFromEpoch: 0),
            Sessionizer.Input(id: "ghost", date: nil, bucket: nil),
        ])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertTrue(drafts.last!.isUndated)
    }

    func testDeterminismUnderShuffle() {
        let inputs = (0..<50).map { index in
            input("asset-\(index)", minutesFromEpoch: Double(index) * 3)
        }
        let a = Sessionizer.sessionize(inputs)
        let b = Sessionizer.sessionize(inputs.shuffled())
        XCTAssertEqual(a.map(\.memberIds), b.map(\.memberIds))
    }
}

final class KeepBestKernelTests: XCTestCase {
    private func member(
        _ id: String, sharpness: Double?, faceQuality: Double? = nil,
        eyesOpen: Double? = nil, megapixels: Double = 12
    ) -> KeepBestKernel.Member {
        KeepBestKernel.Member(
            id: id, sharpness: sharpness, faceCount: faceQuality == nil ? 0 : 1,
            bestFaceQuality: faceQuality, eyesOpenMin: eyesOpen,
            saliencyArea: nil, megapixels: megapixels
        )
    }

    func testSharpestWins() {
        let result = KeepBestKernel.evaluate([
            member("soft", sharpness: 5),
            member("sharp", sharpness: 80),
        ])
        XCTAssertEqual(result.keeperId, "sharp")
        XCTAssertTrue(result.keeperChips.contains(.sharpest))
    }

    func testAllDegenerateTriggersHumility() {
        // Identical everything: σ = 0 on every component → no keeper.
        let result = KeepBestKernel.evaluate([
            member("a", sharpness: 50),
            member("b", sharpness: 50),
        ])
        XCTAssertNil(result.keeperId)
        XCTAssertTrue(result.isHumility)
    }

    func testMixedFaceClusterPenalizesFaceless() {
        let result = KeepBestKernel.evaluate([
            member("faceless", sharpness: 50, faceQuality: nil),
            member("smiling", sharpness: 50, faceQuality: 0.9, eyesOpen: 1.0),
        ])
        XCTAssertEqual(result.keeperId, "smiling")
    }

    func testEyesClosedLoses() {
        let result = KeepBestKernel.evaluate([
            member("blink", sharpness: 50, faceQuality: 0.8, eyesOpen: 0.05),
            member("open", sharpness: 50, faceQuality: 0.8, eyesOpen: 1.0),
        ])
        XCTAssertEqual(result.keeperId, "open")
    }
}

final class CalibrationTests: XCTestCase {
    func testTightensOnHighRejection() {
        let state = UserCalibration(detectorId: "blur")
        let decisions = (0..<20).map { DecisionSample(accepted: $0 % 2 == 0) } // 50% rejection
        let next = CalibrationStepper.step(state: state, trailingDecisions: decisions)
        XCTAssertEqual(next.stepOffset, 1)
    }

    func testRestoreTightensTwoSteps() {
        let state = UserCalibration(detectorId: "blur")
        let next = CalibrationStepper.step(
            state: state,
            trailingDecisions: [DecisionSample(accepted: true, restoredFromStaging: true)]
        )
        XCTAssertEqual(next.stepOffset, 2)
    }

    func testRelaxAfterSustainedAcceptance() {
        var state = UserCalibration(detectorId: "blur", stepOffset: 2, decisionsSinceChange: 49)
        let decisions = (0..<20).map { _ in DecisionSample(accepted: true) }
        state = CalibrationStepper.step(state: state, trailingDecisions: decisions)
        XCTAssertEqual(state.stepOffset, 1, "offsets relax after 50 quiet decisions — early streaks aren't permanent")
    }

    func testOperatingPointClamping() {
        let table = CalibrationTable(
            detectorId: "blur", visionRevision: nil,
            points: [
                OperatingPoint(threshold: 5, precision: 0.95, recall: 0.4),
                OperatingPoint(threshold: 15, precision: 0.85, recall: 0.7),
                OperatingPoint(threshold: 25, precision: 0.7, recall: 0.9),
            ],
            defaultIndex: 1
        )
        XCTAssertEqual(table.point(stepOffset: -10).threshold, 5)
        XCTAssertEqual(table.point(stepOffset: 10).threshold, 25)
    }
}

final class DupeClustererTests: XCTestCase {
    private func candidate(
        _ id: String, phash: UInt64, size: Int64? = 1_000,
        favorite: Bool = false, date: Double = 1_000
    ) -> DupeClusterer.Candidate {
        DupeClusterer.Candidate(
            stub: AssetStub(
                id: id, mediaKind: .image,
                createdAt: Date(timeIntervalSince1970: date),
                pixelWidth: 4_032, pixelHeight: 3_024, isFavorite: favorite
            ),
            phash: phash, fileSize: size
        )
    }

    func testExactPairConfirms() {
        let clusters = DupeClusterer.confirmClusters(in: [
            candidate("a", phash: 0xABCD),
            candidate("b", phash: 0xABCD),
        ])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberIds.count, 1)
    }

    func testDifferentFileSizeSplits() {
        let clusters = DupeClusterer.confirmClusters(in: [
            candidate("a", phash: 0xABCD, size: 1_000),
            candidate("b", phash: 0xABCD, size: 2_000),
        ])
        XCTAssertTrue(clusters.isEmpty, "same hash, different bytes ≠ exact dupes")
    }

    func testFavoriteIsAlwaysTheKeeper() {
        let clusters = DupeClusterer.confirmClusters(in: [
            candidate("plain", phash: 1, favorite: false),
            candidate("loved", phash: 1, favorite: true),
        ])
        XCTAssertEqual(clusters[0].keeperId, "loved")
        XCTAssertEqual(clusters[0].memberIds, ["plain"])
    }

    func testDeterminismUnderShuffle() {
        let candidates = (0..<12).map { candidate("asset-\($0)", phash: UInt64($0 < 6 ? 10 : 999_999)) }
        let a = DupeClusterer.confirmClusters(in: candidates)
        let b = DupeClusterer.confirmClusters(in: candidates.reversed())
        XCTAssertEqual(a.map(\.memberIds), b.map(\.memberIds))
        XCTAssertEqual(a.map(\.keeperId), b.map(\.keeperId))
    }
}

final class ProposalDraftTests: XCTestCase {
    func testDedupeKeyIsOrderInsensitive() {
        func draft(_ members: [String]) -> ProposalDraft {
            ProposalDraft(
                actionType: .exactDuplicate, unit: .cluster, memberIds: members,
                keeperId: "keeper", reason: ReasonParams(key: "reason.dupe.identical"),
                regretTier: 0, confidence: 1, estBytes: 0
            )
        }
        XCTAssertEqual(draft(["a", "b"]).dedupeKey, draft(["b", "a"]).dedupeKey)
        XCTAssertNotEqual(draft(["a", "b"]).dedupeKey, draft(["a", "c"]).dedupeKey)
    }

    func testEveryRegistryTemplateRenders() {
        // The CI shipping bar (SCAN_PIPELINE.md §5-S7): a detector that can't
        // render its reason doesn't ship. Smoke-check the catalog's coverage.
        for templateId in ReasonCatalog.knownTemplateIds {
            let params: ReasonParams
            switch templateId {
            case "reason.dupe.nearDuplicate":
                params = ReasonParams(key: templateId, args: ["keptQuality": .string("larger")])
            case "reason.burst.keepBest", "reason.similar.pickFavorite":
                params = ReasonParams(key: templateId, args: ["count": .int(8)])
            case "reason.similar.keepBest":
                params = ReasonParams(key: templateId, args: ["count": .int(8), "chips": .string("sharpest")])
            case "reason.junk.blurry":
                params = ReasonParams(key: templateId, args: ["sharpness": .double(12)])
            case "reason.screenshot.aged":
                params = ReasonParams(key: templateId, args: ["ageMonths": .int(14)])
            default:
                params = ReasonParams(key: templateId)
            }
            XCTAssertNotNil(ReasonCatalog.render(params), "template \(templateId) must render")
        }
    }
}

final class SimilarClustererTests: XCTestCase {
    func testClustersByEmbeddingAndSplitsFarApart() {
        let members = [
            SimilarClusterer.Member(id: "a", phash: 0, capturedAt: Date(timeIntervalSince1970: 0)),
            SimilarClusterer.Member(id: "b", phash: 0, capturedAt: Date(timeIntervalSince1970: 2)),
            SimilarClusterer.Member(id: "c", phash: 0, capturedAt: Date(timeIntervalSince1970: 4)),
        ]
        let distances = FeatureDistanceComputer(visionRevision: 2) { a, b in
            // a↔b close; c far from both.
            if Set([a, b]) == Set(["a", "b"]) { return 0.2 }
            return 0.9
        }
        let clusters = SimilarClusterer.cluster(members: members, distances: distances)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].memberIds, ["a", "b"])
    }

    func testNarrativeSpreadDemotes() {
        let members = [
            SimilarClusterer.Member(id: "a", phash: 0, capturedAt: Date(timeIntervalSince1970: 0)),
            SimilarClusterer.Member(id: "b", phash: 0, capturedAt: Date(timeIntervalSince1970: 180)),
        ]
        let distances = FeatureDistanceComputer(visionRevision: 2) { _, _ in 0.1 }
        let clusters = SimilarClusterer.cluster(members: members, distances: distances)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertGreaterThan(clusters[0].narrativeDemotion, 0.9, "3-minute spread ≈ narrative sequence")
    }
}
