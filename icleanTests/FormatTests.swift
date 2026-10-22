import Foundation
import Testing

@testable import iclean

/// The lengths of videos in text (copy:C1): rounded once, so nothing ever reads "60 min".
@Suite struct FormatTests {
    private static var isEnglish: Bool { Locale.current.language.languageCode == .english }

    /// Every whole second up to four hours: no length says 60 of anything.
    @Test func shortDurationNeverSaysSixty() {
        for total in 0...(4 * 3600) {
            let text = Format.durationShort(Double(total))
            #expect(
                text.range(of: #"(?<!\d)60(?!\d)"#, options: .regularExpression) == nil,
                "\(total) s: \(text)")
        }
    }

    /// The same, with the fractions a real video has (the length is not a whole number of seconds).
    @Test func shortDurationNeverSaysSixtyForFractionalLengths() {
        var seconds = 0.0
        while seconds < 3 * 3600 {
            let text = Format.durationShort(seconds)
            #expect(
                text.range(of: #"(?<!\d)60(?!\d)"#, options: .regularExpression) == nil,
                "\(seconds) s: \(text)")
            seconds += 0.37
        }
    }

    @Test(.enabled(if: Self.isEnglish)) func shortDurationCarriesIntoTheHour() {
        // 59 min 30 s is 1 hour, not "60 min".
        #expect(Format.durationShort(3570) == "1 hr")
        // 1 h 59 min 40 s is 2 hours, not "1 hr, 60 mins".
        #expect(Format.durationShort(7180) == "2 hrs")
        #expect(Format.durationShort(7199) == "2 hrs")
        #expect(Format.durationShort(86370) == "24 hrs")
    }

    @Test(.enabled(if: Self.isEnglish)) func shortDurationReadsInUnits() {
        #expect(Format.durationShort(12) == "12 secs.")
        // 59.6 s rounds to a minute.
        #expect(Format.durationShort(59.6) == "1 min")
        #expect(Format.durationShort(300) == "5 mins")
        #expect(Format.durationShort(3630) == "1 hr, 1 min")
        #expect(Format.durationShort(3660) == "1 hr, 1 min")
        #expect(Format.durationShort(7320) == "2 hrs, 2 mins")
    }

    @Test func shortDurationSurvivesNonsense() {
        #expect(!Format.durationShort(.nan).isEmpty)
        #expect(!Format.durationShort(-5).isEmpty)
        #expect(!Format.durationShort(.infinity).isEmpty)
    }

    /// The clock pattern follows the rounded length: 3599.6 s is an hour, not "60:00".
    @Test(.enabled(if: Self.isEnglish)) func clockDurationChoosesThePatternFromTheRoundedLength() {
        #expect(Format.duration(3599.6) == "1:00:00")
        #expect(Format.duration(3599.4) == "59:59")
        #expect(Format.duration(5) == "0:05")
        #expect(Format.duration(300) == "5:00")
        #expect(Format.duration(3723) == "1:02:03")
    }

    @Test func spokenDurationIsWholeUnits() {
        let text = Format.durationSpoken(3599.6)
        #expect(text.range(of: #"(?<!\d)60(?!\d)"#, options: .regularExpression) == nil, "\(text)")
    }
}
