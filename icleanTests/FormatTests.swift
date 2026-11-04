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

    /// The system's abbreviations differ between releases: iOS 27 says "12 secs." and "2 hrs", iOS 26
    /// says "12 sec" and "2 hr". These tests are about the numbers and the units (rounding, carrying),
    /// so they compare without the plural "s" and the full stop.
    private static func stems(_ text: String) -> String {
        text.replacingOccurrences(of: #"(sec|min|hr)s?\.?"#, with: "$1", options: .regularExpression)
    }

    @Test func theStemsIgnorePluralsAndFullStopsOnly() {
        #expect(Self.stems("12 secs.") == "12 sec")
        #expect(Self.stems("12 sec") == "12 sec")
        #expect(Self.stems("2 hrs, 2 mins") == "2 hr, 2 min")
        #expect(Self.stems("1 hr, 1 min") == "1 hr, 1 min")
        // The numbers and their order are kept: a wrong number is still wrong.
        #expect(Self.stems("2 hrs, 60 mins") == "2 hr, 60 min")
    }

    @Test(.enabled(if: Self.isEnglish)) func shortDurationCarriesIntoTheHour() {
        // 59 min 30 s is 1 hour, not "60 min".
        #expect(Self.stems(Format.durationShort(3570)) == "1 hr")
        // 1 h 59 min 40 s is 2 hours, not "1 hr, 60 mins".
        #expect(Self.stems(Format.durationShort(7180)) == "2 hr")
        #expect(Self.stems(Format.durationShort(7199)) == "2 hr")
        #expect(Self.stems(Format.durationShort(86370)) == "24 hr")
    }

    @Test(.enabled(if: Self.isEnglish)) func shortDurationReadsInUnits() {
        #expect(Self.stems(Format.durationShort(12)) == "12 sec")
        // 59.6 s rounds to a minute.
        #expect(Self.stems(Format.durationShort(59.6)) == "1 min")
        #expect(Self.stems(Format.durationShort(300)) == "5 min")
        #expect(Self.stems(Format.durationShort(3630)) == "1 hr, 1 min")
        #expect(Self.stems(Format.durationShort(3660)) == "1 hr, 1 min")
        #expect(Self.stems(Format.durationShort(7320)) == "2 hr, 2 min")
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
