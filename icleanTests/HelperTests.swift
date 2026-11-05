import CleanupKit
import CoreGraphics
import Foundation
import Testing

@testable import iclean

/// The small helpers the screens share: sizes said aloud, plural agreement, the words of a review
/// state and the clamp. Logic of the app target; the model and the detectors are tested in the
/// package.
@Suite struct HelperTests {
    private static var isEnglish: Bool { Locale.current.language.languageCode == .english }

    // MARK: Sizes said aloud

    @Test(.enabled(if: Self.isEnglish)) func sizesAreSaidInWordsNotAbbreviations() {
        #expect(SpokenBytes.string(36_000_000) == "36 megabytes")
        #expect(SpokenBytes.string(2_500_000_000) == "2.5 gigabytes")
        #expect(SpokenBytes.string(3_000_000_000_000) == "3 terabytes")
    }

    @Test(.enabled(if: Self.isEnglish)) func anEstimateSaysSo() {
        #expect(SpokenBytes.string(36_000_000, estimate: true) == "about 36 megabytes")
        #expect(SpokenBytes.string(36_000_000, estimate: false) == "36 megabytes")
    }

    /// Whatever the size, VoiceOver gets words: no “MB”, no “GB” for it to spell out.
    @Test func noSizeIsSaidInLetters() {
        let samples: [Int64] = [
            0, 1, 999, 1_000, 123_456, 999_999, 5_000_000, 36_000_000, 999_999_999, 4_200_000_000,
            1_000_000_000_000, 7_300_000_000_000,
        ]
        for bytes in samples {
            let text = SpokenBytes.string(bytes)
            let abbreviation = text.range(of: #"\b[KMGT]?B\b"#, options: .regularExpression)
            #expect(!text.isEmpty, "\(bytes)")
            #expect(abbreviation == nil, "\(bytes): \(text)")
        }
    }

    /// Ten times the bytes is never said the same way.
    @Test func eachPowerOfTenIsSaidDifferently() {
        var said: [String] = []
        var bytes: Int64 = 1
        for _ in 0..<12 {
            said.append(SpokenBytes.string(bytes))
            bytes *= 10
        }
        #expect(Set(said).count == said.count, "\(said)")
    }

    // MARK: Agreement

    @Test(.enabled(if: Self.isEnglish)) func aCountAndItsNounAgree() {
        let one = String(agreeing: AttributedString(localized: "^[\(1) item](inflect: true)"))
        let many = String(agreeing: AttributedString(localized: "^[\(12) item](inflect: true)"))
        #expect(one == "1 item")
        #expect(many == "12 items")
    }

    // MARK: The words of a review

    @Test func aReviewStateIsToldInWords() {
        let selected = ReviewState.text(selected: true)
        let staying = ReviewState.text(selected: false)
        #expect(!selected.isEmpty)
        #expect(!staying.isEmpty)
        #expect(selected != staying)
    }

    @Test func everyKindOfItemHasAName() {
        let kinds: [ItemKind] = [.photo, .screenshot, .livePhoto, .video, .screenRecording]
        let names = kinds.map(\.spokenName)
        #expect(names.allSatisfy { !$0.isEmpty }, "\(names)")
        #expect(Set(names).count == names.count, "\(names)")
    }

    // MARK: The clamp

    @Test func aValueIsHeldBetweenTwoLimits() {
        let range: ClosedRange<CGFloat> = 10...20
        #expect(CGFloat(5).clamped(to: range) == 10)
        #expect(CGFloat(25).clamped(to: range) == 20)
        #expect(CGFloat(15).clamped(to: range) == 15)
        // The limits themselves are inside.
        #expect(CGFloat(10).clamped(to: range) == 10)
        #expect(CGFloat(20).clamped(to: range) == 20)
        #expect((-CGFloat.infinity).clamped(to: range) == 10)
        #expect(CGFloat.infinity.clamped(to: range) == 20)
    }

    @Test func aSinglePointRangeAlwaysAnswersThatPoint() {
        let point: ClosedRange<CGFloat> = 4...4
        for value in [CGFloat(-1), 0, 4, 9] {
            #expect(value.clamped(to: point) == 4)
        }
    }
}
