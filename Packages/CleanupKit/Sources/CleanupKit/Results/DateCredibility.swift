import Foundation

/// Why a copy's date looks unreliable. Shown to the person as a short note.
public enum DateReason: String, Sendable, Codable, Hashable, CaseIterable {
    /// The copy has no date at all.
    case missing
    /// The date is a default value: the start of 1970, 2001 or 1904.
    case placeholder
    /// The date has not happened yet.
    case inFuture
    /// The date is when this copy was saved to the library, while another copy of the same photo
    /// still carries an earlier capture date.
    case savedDate
    /// Many photos carry exactly this timestamp: a bulk import stamped them all alike.
    case sharedStamp
    /// The date has no time of day (exactly midnight).
    case midnight
    /// This copy has no location while another copy of the same photo has one: it was probably
    /// re-saved by an app that strips the details.
    case strippedLocation

    /// A date nobody could have taken a photo at.
    public var isImpossible: Bool { self == .missing || self == .placeholder || self == .inFuture }

    /// How much the reason counts against a copy's date. Impossible dates count far more than the
    /// others together.
    var weight: Int {
        switch self {
        case .missing, .placeholder, .inFuture: DateThresholds.impossibleWeight
        case .savedDate: 10
        case .sharedStamp: 5
        case .strippedLocation: 2
        case .midnight: 1
        }
    }
}

public enum DateThresholds {
    static let impossibleWeight = 1000
    /// Dates this close are the same moment: the copy that was saved a few minutes later, or a
    /// camera and its phone a few seconds apart, do not make one date more likely than the other.
    public static let sameMoment: TimeInterval = 3600
    /// A copy was dated by when it was saved if its date is this close to its added date.
    public static let savedWindow: TimeInterval = 2 * 3600
    /// Another copy keeps a capture date if its date is at least this much older than the date
    /// it was added to the library.
    public static let preservedGap: TimeInterval = 24 * 3600
    /// This many photos with the very same timestamp (to the second) look like a bulk import. The
    /// copies of one photo count once.
    public static let sharedStampCount = 5
    /// A date later than the earliest believable date of the best copies by more than this is the
    /// date of a later copy, whatever small doubts there are about the earlier date: a scanned
    /// photo dated to the day (so, to midnight) is still far likelier to be right than a copy
    /// made years afterwards.
    public static let farFromEarliest: TimeInterval = 366 * 24 * 3600
    /// How far ahead of now a date may be before it counts as in the future (time zones, clocks).
    public static let futureSlack: TimeInterval = 24 * 3600
}

/// What is known about one copy's date.
public struct DateAssessment: Sendable, Hashable {
    public var reasons: [DateReason]

    public init(reasons: [DateReason] = []) {
        self.reasons = reasons
    }

    public var isImpossible: Bool { reasons.contains { $0.isImpossible } }

    /// Everything that counts against the date except an impossible date.
    public var softPenalty: Int {
        reasons.filter { !$0.isImpossible }.reduce(0) { $0 + $1.weight }
    }
}

/// Facts about the whole library that help judge a date. Cheap to build once per detection run.
public struct DateContext: Sendable {
    public var now: Date
    /// Photos per timestamp, to the second, over the library. Frames of a burst are not counted:
    /// a camera takes them within a second of each other, which is no sign of an import.
    var stampCounts: [Int64: Int]
    public var calendar: Calendar

    /// Nothing known about the library; judges a group on its own facts only.
    public static var empty: DateContext {
        DateContext(now: .now, stampCounts: [:], calendar: .current)
    }

    public init(now: Date = .now, items: [LibraryItem], calendar: Calendar = .current) {
        var counts: [Int64: Int] = [:]
        for item in items where item.metadata.burstID == nil {
            if let date = item.metadata.captureDate { counts[Self.second(date), default: 0] += 1 }
        }
        self.init(now: now, stampCounts: counts, calendar: calendar)
    }

    init(now: Date, stampCounts: [Int64: Int], calendar: Calendar) {
        self.now = now
        self.stampCounts = stampCounts
        self.calendar = calendar
    }

    static func second(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }

    func stampCount(_ date: Date) -> Int { stampCounts[Self.second(date)] ?? 0 }
}

/// Works out which copy of a photo has the date most likely to be the real one.
///
/// A copy made later is dated later: saving, importing, downloading or messaging a photo gives
/// the copy the date of that moment, while the original keeps the moment it was taken. So among
/// copies of one photo the earliest believable date is the most probable capture date. Dates that
/// cannot be right (none, a default, the future) are set aside first, and a date that is only the
/// moment of saving or of a bulk import counts against a copy when another copy shows an earlier
/// capture date. Nothing here changes a photo; it only decides which copy to suggest keeping.
public enum DateCredibility {
    /// Reasons for each copy of one group, by asset id.
    public static func assess(_ items: [LibraryItem], context: DateContext = .empty)
        -> [String: DateAssessment]
    {
        var out: [String: DateAssessment] = [:]
        // Only a known "no location" counts; an unknown one (an item stored before the location was
        // read) is not evidence of anything.
        let anyLocation = items.contains { $0.metadata.hasLocation == true }
        for item in items {
            let m = item.metadata
            var reasons: [DateReason] = []
            if let date = m.captureDate {
                if isPlaceholder(date, context.calendar) {
                    reasons.append(.placeholder)
                } else if date > context.now.addingTimeInterval(DateThresholds.futureSlack) {
                    reasons.append(.inFuture)
                } else {
                    if isSavedDate(item, among: items, calendar: context.calendar) {
                        reasons.append(.savedDate)
                    }
                    if isSharedStamp(item, date: date, among: items, context: context) {
                        reasons.append(.sharedStamp)
                    }
                    if isMidnight(date, context.calendar) { reasons.append(.midnight) }
                }
            } else {
                reasons.append(.missing)
            }
            if anyLocation, m.hasLocation == false { reasons.append(.strippedLocation) }
            out[item.assetID] = DateAssessment(reasons: reasons)
        }
        return out
    }

    /// True when many other photos of the library carry this copy's exact timestamp. The copies of
    /// the photo itself count once, and frames of a burst never count (their timestamps are close
    /// because the camera took them in a row, not because something imported them).
    static func isSharedStamp(
        _ item: LibraryItem, date: Date, among items: [LibraryItem], context: DateContext
    ) -> Bool {
        guard item.metadata.burstID == nil else { return false }
        let second = DateContext.second(date)
        let ownCopies = items.filter {
            $0.metadata.burstID == nil && $0.metadata.captureDate.map(DateContext.second) == second
        }.count
        let others = context.stampCount(date) - ownCopies
        return others + 1 >= DateThresholds.sharedStampCount
    }

    /// True when the copy's date is the moment it was added to the library while another copy
    /// has a clearly earlier capture date that predates the moment that copy was added. A copy
    /// with a default date is not evidence of anything and is ignored.
    static func isSavedDate(
        _ item: LibraryItem, among items: [LibraryItem], calendar: Calendar = .current
    ) -> Bool {
        let m = item.metadata
        guard let date = m.captureDate, let added = m.addedDate,
            abs(added.timeIntervalSince(date)) <= DateThresholds.savedWindow
        else { return false }
        return items.contains { other in
            guard other.assetID != item.assetID, let otherDate = other.metadata.captureDate,
                let otherAdded = other.metadata.addedDate,
                !isPlaceholder(otherDate, calendar)
            else { return false }
            let keepsCaptureDate =
                otherAdded.timeIntervalSince(otherDate) >= DateThresholds.preservedGap
            return keepsCaptureDate && date.timeIntervalSince(otherDate) > DateThresholds.sameMoment
        }
    }

    /// A default date no photo was taken at. Within a day of the start of 1970 (the Unix epoch, also
    /// seen as the last day of 1969 in western time zones) or of 1904 (the QuickTime epoch): no
    /// digital photo is that old. The start of 2001 (the Core Data and Photos reference date) is
    /// matched exactly, in UTC or as local midnight, because real photos exist from the days around
    /// it (the new millennium).
    static func isPlaceholder(_ date: Date, _ calendar: Calendar = .current) -> Bool {
        let t = date.timeIntervalSince1970
        let day: TimeInterval = 86_400
        if abs(t) <= day || abs(t - (-2_082_844_800)) <= day { return true }
        if abs(t - 978_307_200) <= 1 { return true }
        let local = gregorian(calendar).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return local.year == 2001 && local.month == 1 && local.day == 1 && local.hour == 0
            && local.minute == 0 && local.second == 0
    }

    /// The Gregorian calendar in the given calendar's time zone, so that year, month and day mean
    /// the same whichever calendar (Buddhist, Japanese, ...) the person's device uses.
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var g = Calendar(identifier: .gregorian)
        g.timeZone = calendar.timeZone
        return g
    }

    /// Midnight in the device's current time zone (the library keeps no zone per photo).
    static func isMidnight(_ date: Date, _ calendar: Calendar) -> Bool {
        let c = gregorian(calendar).dateComponents(
            [.hour, .minute, .second, .nanosecond], from: date)
        return c.hour == 0 && c.minute == 0 && c.second == 0 && (c.nanosecond ?? 0) == 0
    }
}
