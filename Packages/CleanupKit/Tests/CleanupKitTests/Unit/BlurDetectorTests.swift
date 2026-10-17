import Testing

@testable import CleanupKit

@Suite struct BlurDetectorTests {
    let detector = BlurDetector()

    @Test func flagsOnlyWhenBothSignalsAreLow() {
        let items = [
            Make.item(Make.meta("blurry"), sharpness: 0.3, aesthetics: -0.6),
            Make.item(Make.meta("lowSharpGoodLook"), sharpness: 0.3, aesthetics: 0.4),
            Make.item(Make.meta("sharp"), sharpness: 0.75, aesthetics: -0.5),
            Make.item(Make.meta("noAesthetics"), sharpness: 0.35, aesthetics: nil),
        ]
        let flagged = Set(detector.detect(items: items).flatMap(\.members))
        #expect(flagged == ["blurry", "noAesthetics"])
    }

    @Test func portraitAndLongExposureAreNeverFlagged() {
        let items = [
            Make.item(Make.meta("portrait", portrait: true), sharpness: 0.1, aesthetics: -0.9),
            Make.item(Make.meta("long", longExposure: true), sharpness: 0.1, aesthetics: -0.9),
            Make.item(Make.meta("shot", kind: .screenshot), sharpness: 0.1, aesthetics: -0.9),
            Make.item(Make.meta("vid", kind: .video, duration: 4), sharpness: 0.1, aesthetics: -0.9),
        ]
        #expect(detector.detect(items: items).isEmpty)
    }

    @Test func blurriestFirst() {
        let items = [
            Make.item(Make.meta("b"), sharpness: 0.4),
            Make.item(Make.meta("a"), sharpness: 0.2),
            Make.item(Make.meta("c"), sharpness: 0.5),
        ]
        #expect(detector.detect(items: items).flatMap(\.members) == ["a", "b", "c"])
    }

    @Test func cloudPreviewsHaveLowerConfidence() {
        let items = [Make.item(Make.meta("c"), source: .cloudPreview, sharpness: 0.2)]
        #expect(detector.detect(items: items).first?.confidence == .lower)
    }

    @Test func alwaysKeepIsRespectedOnTheNextScan() {
        let items = [Make.item(Make.meta("x"), sharpness: 0.2), Make.item(Make.meta("y"), sharpness: 0.2)]
        let builder = DefaultResultsBuilder(detectors: [detector])
        let results = builder.buildResults(items: items, keepMarks: ["x"])
        #expect(results.category(.blurry)?.allMembers == ["y"])
        #expect(results.defaultSelection == ["y"])
    }
}
