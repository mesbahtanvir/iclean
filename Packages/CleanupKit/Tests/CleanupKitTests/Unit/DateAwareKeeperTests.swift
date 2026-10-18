import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Which copy to keep when copies of one photo carry different dates: the one whose date is most
/// probably the real one. See `DateCredibility`.
@Suite struct DateAwareKeeperTests {
    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func day(_ y: Int, _ m: Int, _ d: Int, _ hh: Int = 15, _ mm: Int = 20, _ ss: Int = 41) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hh, minute: mm, second: ss))!
    }

    /// A reference "now" so future dates are judged the same on every run.
    var now: Date { day(2024, 1, 1) }

    func copy(
        _ id: String, date: Date?, added: Date? = nil, w: Int = 4032, h: Int = 3024,
        size: Int64 = 3_000_000, location: Bool = false, favorite: Bool = false
    ) -> LibraryItem {
        var m = Make.meta(id, width: w, height: h, favorite: favorite)
        m.captureDate = date
        m.modificationDate = date
        m.addedDate = added
        m.hasLocation = location
        return LibraryItem(
            metadata: m, analysisSource: .localPreview,
            analysis: Analysis(dHash: 1, featurePrint: Data(), sharpness: 1), byteSize: size)
    }

    /// The suggested keeper. Every call also checks that the order the copies come in does not matter.
    func keeper(_ items: [LibraryItem], context: DateContext? = nil) -> String? {
        let ctx = context ?? DateContext(now: now, items: items, calendar: utc)
        let first = KeeperRules.duplicateKeepers(items, context: ctx).first
        for _ in 0..<20 {
            #expect(KeeperRules.duplicateKeepers(items.shuffled(), context: ctx).first == first)
        }
        return first
    }

    // MARK: Exact copies with different dates

    @Test func theEarliestBelievableDateIsKeptAmongExactCopies() {
        // A copy made later is dated later, so the earlier date is the more probable capture date.
        // The later copy has the id that sorts first and the same size: only the date separates them.
        let items = [
            copy("a-saved-later", date: day(2023, 9, 10)),
            copy("z-original", date: day(2019, 6, 1)),
        ]
        #expect(keeper(items) == "z-original")
    }

    @Test func datesWithinAnHourAreTheSameMoment() {
        // Same size, dates minutes apart: the date does not decide; the older one is still the
        // last tie-break.
        let items = [
            copy("later", date: day(2019, 6, 1, 15, 50)),
            copy("earlier", date: day(2019, 6, 1, 15, 20)),
        ]
        #expect(keeper(items) == "earlier")
        // ...and a larger file wins when the dates are the same moment.
        let bigger = [
            copy("small", date: day(2019, 6, 1, 15, 20), size: 1_000_000),
            copy("big", date: day(2019, 6, 1, 15, 50), size: 3_000_000),
        ]
        #expect(keeper(bigger) == "big")
    }

    @Test func aMuchEarlierDateBeatsALargerFileOfTheSameResolution() {
        let items = [
            copy("original", date: day(2019, 6, 1), size: 2_000_000),
            copy("resaved", date: day(2023, 9, 10), size: 3_400_000),
        ]
        #expect(keeper(items) == "original")
    }

    @Test func resolutionStillWinsWhenBothDatesAreBelievable() {
        let items = [
            copy("small-old", date: day(2019, 6, 1), w: 2016, h: 1512),
            copy("large-new", date: day(2023, 9, 10)),
        ]
        #expect(keeper(items) == "large-new")
    }

    @Test func favoritesAreStillAlwaysKept() {
        let items = [
            copy("fav", date: day(2023, 9, 10), favorite: true),
            copy("original", date: day(2019, 6, 1)),
        ]
        #expect(
            KeeperRules.duplicateKeepers(
                items, context: DateContext(now: now, items: items, calendar: utc)) == ["fav"])
    }

    // MARK: Dates that cannot be right

    @Test func aDefaultDateLosesEvenToALowerResolutionCopy() {
        for placeholder in [
            Date(timeIntervalSince1970: 0), day(2001, 1, 1, 0, 0, 0), day(1904, 1, 1, 0, 0, 0),
            Date(timeIntervalSince1970: -3600),
        ] {
            let items = [
                copy("big-no-date", date: placeholder),
                copy("small-dated", date: day(2019, 6, 1), w: 2016, h: 1512),
            ]
            #expect(keeper(items) == "small-dated", "\(placeholder)")
        }
    }

    @Test func realPhotosFromTheMillenniumAreNotDefaultDates() {
        // New Year's Eve 2000 and a daytime photo on 1 Jan 2001 are real dates; only the exact
        // default instant (UTC or local midnight) is not.
        for real in [
            day(2000, 12, 31, 23, 40, 0), day(2001, 1, 1, 14, 5, 12), day(2001, 1, 1, 0, 0, 30),
        ] {
            let items = [copy("a", date: real), copy("b", date: day(2023, 9, 10), size: 1)]
            let a = DateCredibility.assess(
                items, context: DateContext(now: now, items: items, calendar: utc))
            #expect(a["a"]?.isImpossible == false, "\(real)")
        }
        // Local midnight on 1 Jan 2001 in another time zone is the default too.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let localMidnight = tokyo.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        #expect(DateCredibility.isPlaceholder(localMidnight, tokyo))
    }

    @Test func aMissingDateLoses() {
        let items = [
            copy("none", date: nil), copy("dated", date: day(2019, 6, 1), w: 2016, h: 1512),
        ]
        #expect(keeper(items) == "dated")
    }

    @Test func aDateInTheFutureLoses() {
        let items = [
            copy("future", date: day(2031, 3, 3)),
            copy("real", date: day(2019, 6, 1), w: 2016, h: 1512),
        ]
        #expect(keeper(items) == "real")
        // A date a few hours ahead of this phone's clock is a time zone, not the future.
        let slack = [
            copy("a", date: now.addingTimeInterval(5 * 3600)),
            copy("b", date: day(2023, 1, 1), size: 1),
        ]
        #expect(
            DateCredibility.assess(
                slack, context: DateContext(now: now, items: slack, calendar: utc))["a"]?
                .isImpossible == false)
    }

    @Test func whenEveryDateIsADefaultTheOldRulesDecide() {
        let items = [
            copy("small", date: Date(timeIntervalSince1970: 0), w: 2016, h: 1512),
            copy("large", date: Date(timeIntervalSince1970: 0)),
        ]
        #expect(keeper(items) == "large")
    }

    // MARK: Dates that are only the moment of saving

    @Test func aCopyDatedByWhenItWasSavedLosesToOneThatKeepsItsCaptureDate() {
        let saved = day(2023, 9, 10, 12, 0, 0)
        let items = [
            // Saved to the library on 10 Sep 2023 and dated that moment; a bigger file.
            copy("saved", date: saved, added: saved, size: 3_400_000),
            // Added the same day, but still carrying the date it was taken.
            copy(
                "original", date: day(2019, 6, 1), added: saved.addingTimeInterval(60),
                size: 2_000_000),
        ]
        #expect(keeper(items) == "original")
        let notes = KeeperRules.dateNotes(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(notes["saved"] == [.savedDate])
        #expect(notes["original"] == nil)
    }

    @Test func copiesTakenAndAddedTogetherAreNotPenalized() {
        let t = day(2023, 9, 10, 12, 0, 0)
        let items = [
            copy("a", date: t, added: t.addingTimeInterval(5)),
            copy("b", date: t.addingTimeInterval(30), added: t.addingTimeInterval(40)),
        ]
        let assessments = DateCredibility.assess(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(assessments.values.allSatisfy { $0.reasons.isEmpty })
    }

    @Test func theSavedDateRuleNeedsTheAddedDate() {
        // Before iOS 26 the added date is not known: nothing is guessed from it.
        let items = [
            copy("saved-later", date: day(2023, 9, 10), added: nil, size: 3_400_000),
            copy("original", date: day(2019, 6, 1), added: nil, size: 2_000_000),
        ]
        #expect(DateCredibility.assess(items)["saved-later"]?.reasons.contains(.savedDate) == false)
        // The earlier date still wins on its own.
        #expect(keeper(items) == "original")
    }

    @Test func anEarlierSavedDateIsNotPenalized() {
        // The copy dated at its adding moment is the EARLIER one, so the other copy cannot be the
        // original: no reason to doubt it.
        let added = day(2019, 6, 1, 12, 0, 0)
        let items = [
            copy("early-saved", date: added, added: added),
            copy("later", date: day(2023, 9, 10), added: day(2023, 9, 10, 0, 5, 0)),
        ]
        let a = DateCredibility.assess(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(a["early-saved"]?.reasons.contains(.savedDate) == false)
    }

    // MARK: Bulk imports and bare midnights

    @Test func aTimestampSharedByManyPhotosCountsAgainstACopy() {
        let stamp = day(2022, 11, 5, 9, 0, 0)
        let a = copy("a-bulk", date: stamp)
        let b = copy("b-unique", date: day(2022, 11, 20, 13, 7, 22))
        // Four other photos carry exactly the same timestamp: a batch import stamped them alike.
        let others = (0..<4).map { copy("other\($0)", date: stamp) }
        let context = DateContext(now: now, items: [a, b] + others, calendar: utc)
        #expect(
            DateCredibility.assess([a, b], context: context)["a-bulk"]?.reasons == [.sharedStamp])
        // The bulk stamp is earlier, but it is the stamp of an import: the unique date is kept.
        #expect(keeper([a, b], context: context) == "b-unique")
    }

    @Test func fewPhotosWithTheSameSecondAreNotABulkImport() {
        let stamp = day(2022, 11, 5, 9, 0, 0)
        let items = [copy("a", date: stamp), copy("b", date: stamp)]
        let context = DateContext(now: now, items: items, calendar: utc)
        #expect(
            DateCredibility.assess(items, context: context).values.allSatisfy { $0.reasons.isEmpty }
        )
    }

    @Test func aBareMidnightIsOnlyASmallDoubt() {
        let items = [
            copy("midnight", date: day(2019, 6, 1, 0, 0, 0)),
            copy(
                "timed", date: day(2019, 6, 1, 0, 0, 0).addingTimeInterval(14 * 3600 + 20 * 60 + 41)
            ),
        ]
        let a = DateCredibility.assess(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(a["midnight"]?.reasons == [.midnight])
        #expect(a["timed"]?.reasons.isEmpty == true)
        // Same day: the same moment? No, 14 hours apart: the midnight copy is the earlier date,
        // but the doubt about it comes first.
        #expect(keeper(items) == "timed")
    }

    // MARK: Other details

    @Test func theCopyThatKeptItsLocationIsKept() {
        let items = [
            copy("stripped", date: day(2019, 6, 1, 15, 20, 41), size: 3_400_000),
            copy("with-gps", date: day(2019, 6, 1, 15, 25, 0), size: 2_000_000, location: true),
        ]
        #expect(keeper(items) == "with-gps")
        let notes = KeeperRules.dateNotes(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(notes["stripped"] == [.strippedLocation])
    }

    @Test func noLocationOnEitherCopyIsNotMentioned() {
        let items = [copy("a", date: day(2019, 6, 1)), copy("b", date: day(2023, 9, 10))]
        let a = DateCredibility.assess(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(a.values.allSatisfy { !$0.reasons.contains(.strippedLocation) })
    }

    // MARK: Notes

    @Test func noNotesWhenNothingSeparatesTheCopies() {
        let items = [copy("a", date: day(2019, 6, 1)), copy("b", date: day(2023, 9, 10))]
        #expect(
            KeeperRules.dateNotes(
                items, context: DateContext(now: now, items: items, calendar: utc)
            ).isEmpty)
        let both = [copy("a", date: nil), copy("b", date: nil)]
        #expect(
            KeeperRules.dateNotes(both, context: DateContext(now: now, items: both, calendar: utc))
                .isEmpty)
    }

    @Test func theKeeperChoiceDoesNotDependOnTheOrderOfTheCopies() {
        let saved = day(2023, 9, 10, 12, 0, 0)
        let items = [
            copy("saved", date: saved, added: saved, size: 3_400_000),
            copy(
                "original", date: day(2019, 6, 1), added: saved.addingTimeInterval(60),
                size: 2_000_000),
            copy("no-date", date: nil, size: 9_000_000),
            copy("stripped", date: day(2019, 6, 1, 0, 0, 0), size: 2_000_000),
        ]
        let context = DateContext(now: now, items: items, calendar: utc)
        let expected = KeeperRules.duplicateKeepers(items, context: context)
        for _ in 0..<20 {
            #expect(KeeperRules.duplicateKeepers(items.shuffled(), context: context) == expected)
        }
    }

    // MARK: Found by review

    @Test func aDefaultDatedCopyDoesNotMakeTheNativeOriginalLookSaved() {
        // P: dated 1970 (added to the library in 2024). N: a camera original added seconds after it
        // was taken. R: the same photo imported again in 2024 with the right date. P must not make N
        // look like "a copy dated when it was saved".
        let taken = day(2019, 6, 1, 14, 20, 41)
        let added2024 = day(2024, 5, 5, 9, 0, 0)
        let p = copy("p-default", date: Date(timeIntervalSince1970: 0), added: added2024)
        let n = copy("n-native", date: taken, added: taken.addingTimeInterval(4))
        let r = copy("r-reimport", date: taken, added: added2024)
        let ctx = DateContext(now: now, items: [p, n, r], calendar: utc)
        let a = DateCredibility.assess([p, n, r], context: ctx)
        #expect(a["n-native"]?.reasons.contains(.savedDate) == false)
        #expect(a["p-default"]?.reasons == [.placeholder])
        #expect(keeper([p, n, r], context: ctx) == "n-native")
        // The note shows on the default date only: the native copy has nothing against it.
        let notes = KeeperRules.dateNotes([p, n, r], context: ctx)
        #expect(notes["n-native"] == nil)
    }

    @Test func burstFramesAreNotABulkImport() {
        // Eight frames of a burst share one second; a later exact copy of one frame has a unique date.
        let t = day(2022, 8, 14, 10, 0, 0)
        func frame(_ i: Int) -> LibraryItem {
            var item = copy("frame\(i)", date: t.addingTimeInterval(Double(i) * 0.1))
            item.metadata.burstID = "burst-1"
            return item
        }
        let frames = (0..<8).map(frame)
        let saved = copy("zz-copy-of-frame0", date: day(2024, 2, 2, 8, 30, 12))
        let items = [frames[0], saved]
        let ctx = DateContext(now: now, items: frames + [saved], calendar: utc)
        #expect(DateCredibility.assess(items, context: ctx)["frame0"]?.reasons.isEmpty == true)
        #expect(keeper(items, context: ctx) == "frame0")
    }

    @Test func theCopiesOfOnePhotoCountOnceTowardsABulkImport() {
        // Five exact copies share a second (Photos' Duplicate command does that); a sixth copy is
        // dated later. Nothing outside the group shares the stamp, so it is not a bulk import.
        let t = day(2022, 11, 5, 9, 0, 0)
        let same = (0..<5).map { copy("same\($0)", date: t) }
        let later = copy("later", date: day(2022, 11, 20, 13, 7, 22))
        let items = same + [later]
        let ctx = DateContext(now: now, items: items, calendar: utc)
        #expect(
            DateCredibility.assess(items, context: ctx).values.allSatisfy { $0.reasons.isEmpty })
        #expect(keeper(items, context: ctx)?.hasPrefix("same") == true)
        // With four other photos stamped alike, the same second does look like an import.
        let others = (0..<4).map { copy("other\($0)", date: t) }
        let ctx2 = DateContext(now: now, items: items + others, calendar: utc)
        #expect(DateCredibility.assess(items, context: ctx2)["same0"]?.reasons == [.sharedStamp])
    }

    @Test func aDateYearsEarlierWinsOverAMinorDoubtAboutIt() {
        // A scanned photo dated to the day (so, to midnight) against a copy made decades later.
        let scanned = copy("scanned", date: day(1985, 7, 4, 0, 0, 0))
        let exported = copy("exported", date: day(2022, 11, 2, 15, 41, 9))
        #expect(keeper([scanned, exported]) == "scanned")
        // The same doubt still decides between dates within a year of each other.
        let near = copy(
            "near", date: day(1985, 7, 4, 0, 0, 0).addingTimeInterval(20 * 86_400 + 54_000))
        #expect(keeper([scanned, near]) == "near")
    }

    @Test func aYearIsMeasuredFromTheEarliestOfTheBestCopiesOnly() {
        // A smaller copy dated much earlier does not set the bar: the best copies are compared among
        // themselves, and the lower resolution one loses on resolution first.
        let items = [
            copy("small-early", date: day(2015, 1, 1, 12, 0, 0), w: 2016, h: 1512),
            copy("big-a", date: day(2023, 3, 3, 12, 0, 0)),
            copy("big-b", date: day(2023, 3, 9, 12, 0, 0), size: 5_000_000),
        ]
        // big-a and big-b are a week apart: the earlier one is kept, not the larger file.
        #expect(keeper(items) == "big-a")
    }

    @Test func nearbyDatesAreTheSameMomentAcrossAnHourBoundary() {
        // Two minutes apart but on either side of a clock hour: the same moment, so the larger file wins.
        let items = [
            copy("early-small", date: day(2019, 6, 1, 15, 59, 0), size: 1_000_000),
            copy("late-big", date: day(2019, 6, 1, 16, 1, 0), size: 3_000_000),
        ]
        #expect(keeper(items) == "late-big")
    }

    @Test func removingACopyDropsItsDateNote() {
        let items = [
            copy("a", date: day(2019, 6, 1, 15, 20, 41), size: 3_400_000),
            copy("b", date: day(2019, 6, 1, 15, 25, 0), size: 2_000_000, location: true),
        ]
        let context = DateContext(now: now, items: items, calendar: utc)
        let group = ResultGroup(
            type: .duplicatePhotos, members: ["b", "a"], keepers: ["b"],
            dateNotes: KeeperRules.dateNotes(items, context: context))
        #expect(group.dateNotes["a"] == [.strippedLocation])
    }

    // MARK: Second review

    @Test func defaultDatesAreNotOrderedAmongThemselves() {
        // 1904 at 1 MB against 1970 at 3 MB: neither date can be right, so the file size decides.
        let items = [
            copy("old-default", date: day(1904, 1, 1, 0, 0, 0), size: 1_000_000),
            copy("epoch", date: Date(timeIntervalSince1970: 0), size: 3_000_000),
        ]
        #expect(keeper(items) == "epoch")
        let missing = [
            copy("none", date: nil, size: 3_000_000),
            copy("epoch", date: Date(timeIntervalSince1970: 0), size: 1_000_000),
        ]
        #expect(keeper(missing) == "none")
    }

    @Test func anUnknownLocationIsNotAMissingLocation() {
        // An item stored before the location was read has no answer yet: nothing may be inferred.
        var unknown = copy("unknown", date: day(2019, 6, 1, 15, 20, 41), size: 3_400_000)
        unknown.metadata.hasLocation = nil
        let known = copy(
            "with-gps", date: day(2019, 6, 1, 15, 25, 0), size: 2_000_000, location: true)
        let a = DateCredibility.assess(
            [unknown, known],
            context: DateContext(now: now, items: [unknown, known], calendar: utc))
        #expect(a["unknown"]?.reasons.contains(.strippedLocation) == false)
        // Only a known "no location" counts.
        var none = unknown
        none.metadata.hasLocation = false
        let b = DateCredibility.assess(
            [none, known], context: DateContext(now: now, items: [none, known], calendar: utc))
        #expect(b["unknown"]?.reasons == [.strippedLocation])
    }

    @Test func theSavedMomentOutweighsEveryOtherSmallDoubtAboutACopy() {
        // "original" keeps its capture date but is exact midnight and shares a stamp with four other
        // photos (6 in all); "saved" is only dated by when it was saved (10). The saved moment weighs
        // more than the two doubts together.
        let stamp = day(2019, 6, 1, 0, 0, 0)
        let saved = day(2023, 9, 10, 12, 0, 0)
        let original = copy("original", date: stamp, added: saved.addingTimeInterval(60))
        let savedCopy = copy("saved", date: saved, added: saved)
        let others = (0..<4).map { copy("other\($0)", date: stamp) }
        let ctx = DateContext(now: now, items: [original, savedCopy] + others, calendar: utc)
        let a = DateCredibility.assess([original, savedCopy], context: ctx)
        #expect(a["original"]?.softPenalty == 6)
        #expect(a["saved"]?.softPenalty == 10)
        // ...and the earlier date is the original's anyway; the penalty must not reverse that.
        #expect(keeper([original, savedCopy], context: ctx) == "original")
    }

    @Test func copiesSavedHoursApartAreNotPenalizedWithoutAnEarlierCaptureDate() {
        // Both were dated when they were saved: neither keeps a capture date, so nothing is "saved late".
        let first = day(2023, 9, 10, 8, 0, 0)
        let second = day(2023, 9, 10, 14, 0, 0)
        let items = [copy("a", date: first, added: first), copy("b", date: second, added: second)]
        let a = DateCredibility.assess(
            items, context: DateContext(now: now, items: items, calendar: utc))
        #expect(a.values.allSatisfy { !$0.reasons.contains(.savedDate) })
    }

    @Test func theDefaultInstantIsRecognisedWhateverCalendarTheDeviceUses() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        var bangkok = Calendar(identifier: .gregorian)
        bangkok.timeZone = TimeZone(identifier: "Asia/Bangkok")!
        let localMidnight = bangkok.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        #expect(DateCredibility.isPlaceholder(localMidnight, buddhist))
        // Local midnight of another day in 2001 is just a midnight.
        let other = bangkok.date(from: DateComponents(year: 2001, month: 3, day: 1))!
        #expect(!DateCredibility.isPlaceholder(other, buddhist))
        #expect(DateCredibility.isMidnight(other, buddhist))
    }

    @Test func aSharedStampIsFoundThroughTheResultsBuilder() async throws {
        // End to end: the builder hands the detector the analyzed items, and the stamp count comes
        // from them. Four photos stamped alike are analyzed library photos; they are what counts.
        let base = TestImages.scene(seed: 71)
        let stamp = day(2022, 11, 5, 9, 7, 13)
        func analyzed(_ id: String, date: Date, imageSeed: UInt64? = nil) async throws
            -> LibraryItem
        {
            let image = imageSeed.map { TestImages.scene(seed: $0) } ?? base
            var m = Make.meta(id, width: image.width, height: image.height)
            m.captureDate = date
            m.modificationDate = date
            let analysis = try await DefaultAnalyzer().analyze(image, metadata: m)
            return LibraryItem(
                metadata: m, analysisSource: .localPreview, analysis: analysis, byteSize: 1_000)
        }
        var items = [
            try await analyzed("bulk-copy", date: stamp),
            try await analyzed("unique-copy", date: day(2022, 11, 20, 13, 7, 22)),
        ]
        for i in 0..<4 {
            items.append(try await analyzed("other\(i)", date: stamp, imageSeed: UInt64(900 + i)))
        }
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors(.free))
            .buildResults(items: items, keepMarks: [])
        let group = results.category(.duplicates)?.groups.first
        #expect(group?.keepers == ["unique-copy"])
        #expect(group?.dateNotes["bulk-copy"] == [.sharedStamp])
    }

    @Test func whenTheKeeperIsRemovedTheNextBestIsSuggestedByTheSameRules() {
        let a = copy("a-original", date: day(2019, 6, 1))
        let b = copy("b-saved", date: day(2023, 9, 10), size: 3_400_000)
        let c = copy("c-no-date", date: nil, size: 9_000_000)
        let group = ResultGroup(
            type: .duplicatePhotos, members: ["a-original", "b-saved", "c-no-date"],
            keepers: ["a-original"])
        var results = CleanupResults(
            categories: [CategoryResult(category: .duplicates, groups: [group])],
            defaultSelection: [], notScannedCount: 0,
            items: ["a-original": a, "b-saved": b, "c-no-date": c])
        results = results.removing(["a-original"])
        let g = results.category(.duplicates)?.groups.first
        // b has a possible date, c has none: b is the best of what is left, not the first listed.
        #expect(g?.keepers == ["b-saved"])
    }

    // MARK: Through the detector

    @Test func theDetectorUsesTheLibraryWideContextAndExplainsTheChoice() async throws {
        let base = TestImages.scene(seed: 61)
        let stamp = day(2022, 11, 5, 9, 0, 0)
        func analyzed(_ id: String, date: Date) async throws -> LibraryItem {
            var m = Make.meta(id, width: base.width, height: base.height)
            m.captureDate = date
            m.modificationDate = date
            let analysis = try await DefaultAnalyzer().analyze(base, metadata: m)
            return LibraryItem(
                metadata: m, analysisSource: .localPreview, analysis: analysis, byteSize: 1_000)
        }
        var items = [
            try await analyzed("bulk-copy", date: stamp),
            try await analyzed("unique-copy", date: day(2022, 11, 20, 13, 7, 22)),
        ]
        // Other, unrelated photos that were stamped alike by the same import.
        for i in 0..<4 {
            var m = Make.meta("other\(i)")
            m.captureDate = stamp
            items.append(LibraryItem(metadata: m, analysisSource: .notScanned, analysis: nil))
        }
        let groups = DuplicatePhotoDetector().detect(items: items)
        #expect(groups.count == 1)
        #expect(groups[0].keepers == ["unique-copy"])
        #expect(groups[0].dateNotes["bulk-copy"] == [.sharedStamp])
    }
}
