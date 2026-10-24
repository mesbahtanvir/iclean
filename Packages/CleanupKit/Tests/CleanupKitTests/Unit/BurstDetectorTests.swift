import Foundation
import Testing

@testable import CleanupKit

/// Spec 015, Story 1: every burst with two or more frames is one group, the right frame kept.
@Suite struct BurstDetectorTests {
    func frame(
        _ id: String, burst: String = "B", at seconds: Double = 0, sharpness: Double = 0.8,
        face: Double? = nil, favorite: Bool = false, pick: BurstPick? = nil,
        represents: Bool = false,
        source: AnalysisSource = .localPreview
    ) -> LibraryItem {
        var item = Make.item(
            Make.meta(
                id, date: Date(timeIntervalSince1970: 1_600_000_000 + seconds), favorite: favorite,
                burst: burst, pick: pick, represents: represents),
            source: source, sharpness: sharpness, face: face)
        if !source.hasAnalysis { item.analysis = nil }
        return item
    }

    func build(_ items: [LibraryItem], keepMarks: Set<String> = []) -> CleanupResults {
        DefaultResultsBuilder(detectors: [BurstDetector()]).buildResults(
            items: items, keepMarks: keepMarks)
    }

    @Test func aBurstIsOneGroupWithOneKeeperAndTheRestSelected() {
        let frames = (0..<12).map {
            frame("f\($0)", at: Double($0), sharpness: 0.7 + Double($0) * 0.01)
        }
        let results = build(frames)
        let group = results.category(.bursts)?.groups.first
        #expect(results.category(.bursts)?.groups.count == 1)
        #expect(group?.type == .burst)
        #expect(group?.members.count == 12)
        #expect(group?.keepers == ["f11"])
        #expect(results.defaultSelection.count == 11)
        #expect(!results.defaultSelection.contains("f11"))
    }

    @Test func everyFrameThePersonPickedIsKept() {
        let frames = [
            frame("a", sharpness: 0.9), frame("b", sharpness: 0.5, pick: .userPick),
            frame("c", sharpness: 0.4, pick: .userPick),
            frame("d", sharpness: 0.95, pick: .autoPick),
        ]
        #expect(build(frames).category(.bursts)?.groups.first?.keepers == ["b", "c"])
    }

    @Test func aFavouriteBeatsSharpnessAndAnAutoPick() {
        let frames = [
            frame("a", sharpness: 0.9, pick: .autoPick), frame("b", sharpness: 0.3, favorite: true),
            frame("c", sharpness: 0.8),
        ]
        #expect(build(frames).category(.bursts)?.groups.first?.keepers == ["b"])
    }

    @Test func aKeptFrameIsNeverSelectedAndAWhollyKeptBurstIsNotListed() {
        let frames = [
            frame("a", sharpness: 0.9), frame("b", sharpness: 0.5), frame("c", sharpness: 0.6),
        ]
        let results = build(frames, keepMarks: ["b"])
        #expect(results.category(.bursts)?.groups.first?.keepers == ["a", "b"])
        #expect(results.defaultSelection == ["c"])
        #expect(build(frames, keepMarks: ["a", "b", "c"]).category(.bursts) == nil)
    }

    @Test func theBestFaceWinsAmongFramesWithFacesThenTheSharpest() {
        let frames = [
            frame("sharpNoFace", sharpness: 0.95), frame("face1", sharpness: 0.7, face: 0.5),
            frame("face2", sharpness: 0.75, face: 0.49), frame("face3", sharpness: 0.6, face: 0.9),
        ]
        // face3 has the best face by far; face2 is within 0.02 of face1 and sharper than it.
        #expect(KeeperRules.burstKeepers(frames) == ["face3"])
        #expect(KeeperRules.burstKeepers(Array(frames.prefix(3))) == ["face2"])
    }

    @Test func framesInTheCloudGroupAndFallBackToTheFramePhotosShows() {
        let frames = [
            frame("a", at: 0, represents: false, source: .notScanned),
            frame("b", at: 1, represents: true, source: .notScanned),
            frame("c", at: 2, source: .notScanned),
        ]
        let results = build(frames)
        #expect(results.category(.bursts)?.groups.first?.keepers == ["b"])
        #expect(results.category(.bursts)?.groups.first?.members.first == "b")
        // Nothing marks a frame: the first by capture order.
        let plain = frames.map { f in
            var m = f; m.metadata.representsBurst = false; return m
        }
        #expect(KeeperRules.burstKeepers(plain) == ["a"])
    }

    @Test func aSingleFrameAndNonBurstPhotosListNothing() {
        let items = [frame("alone", burst: "solo"), Make.item(Make.meta("plain"))]
        #expect(build(items).category(.bursts) == nil)
    }

    @Test func burstsComeBeforeSimilarAndAFrameIsListedOnce() {
        let frames = [frame("a", at: 0), frame("b", at: 2), frame("c", at: 4)]
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: frames, keepMarks: [])
        #expect(results.category(.bursts)?.allMembers.count == 3)
        #expect(results.category(.similar) == nil)
        #expect(results.category(of: "a") == .bursts)
    }

    @Test func newestBurstFirstAndAStableOrder() {
        let items = [
            frame("old1", burst: "O", at: 0), frame("old2", burst: "O", at: 1),
            frame("new1", burst: "N", at: 100), frame("new2", burst: "N", at: 101),
        ]
        let groups = BurstDetector().detect(items: items)
        #expect(groups.map { Set($0.members) } == [["new1", "new2"], ["old1", "old2"]])
        #expect(BurstDetector().detect(items: items.reversed()) == groups)
    }

    @Test func faceQualityStaysOnBurstMembersInResults() {
        let frames = [frame("a", at: 0, face: 0.3), frame("b", at: 1, face: 0.8)]
        let results = build(frames)
        #expect(results.items["a"]?.analysis?.faceQuality == 0.3)
    }
}
