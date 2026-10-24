import CleanupKit
import Foundation

enum Format {
    static func bytes(_ bytes: Int64, estimate: Bool) -> String {
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return estimate ? String(localized: "about \(text)") : text
    }

    /// A size without the "about": the figure of the hero, where the "about" is in the line above.
    static func byteValue(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Whole seconds, so the pattern, the text and the carry all see the same number: 3599.6 is "1:00:00",
    /// not "60:00". Not a number (or negative): zero.
    private static func wholeSeconds(_ seconds: Double) -> Int {
        seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
    }

    /// "5:00", "0:12", "1:02:03".
    static func duration(_ seconds: Double) -> String {
        let whole = wholeSeconds(seconds)
        let duration = Duration.seconds(whole)
        return whole >= 3600
            ? duration.formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1)))
            : duration.formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
    }

    /// For VoiceOver: "5 minutes".
    static func durationSpoken(_ seconds: Double) -> String {
        Duration.seconds(wholeSeconds(seconds))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// A length for a line of text, to the minute: "12 secs.", "5 mins", "1 hr, 2 mins". Rounded once
    /// to a whole number of minutes and then split into hours and minutes, so it can never say
    /// "60 mins" or "1 hr, 60 mins"; the words and their order are the system's, per language.
    static func durationShort(_ seconds: Double) -> String {
        let whole = wholeSeconds(seconds)
        guard whole >= 60 else {
            return Duration.seconds(whole).formatted(
                .units(allowed: [.seconds], width: .abbreviated))
        }
        let minutes = Int((Double(whole) / 60).rounded())
        return Duration.seconds(minutes * 60).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// "Scanned just now", "Scanned 3 minutes ago", "Scanned today at 2:14 PM", and so on. Meant to be
    /// drawn inside a `TimelineView(.everyMinute)`, so it never ticks every second.
    static func scanned(_ date: Date, now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "Scanned just now") }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1
                ? String(localized: "Scanned 1 minute ago")
                : String(localized: "Scanned \(minutes) minutes ago")
        }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Scanned today at \(time)") }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Scanned yesterday at \(time)")
        }
        let day = date.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "Scanned \(day) at \(time)")
    }
}

extension CleanupCategory {
    var title: String {
        switch self {
        case .duplicates: String(localized: "Duplicates")
        case .bursts: String(localized: "Bursts")
        case .similar: String(localized: "Similar Shots")
        case .blurry: String(localized: "Blurry Photos")
        case .unimportant: String(localized: "Unimportant")
        case .dark: String(localized: "Dark Photos")
        case .screenshots: String(localized: "Screenshots")
        case .screenRecordings: String(localized: "Screen Recordings")
        case .duplicateVideos: String(localized: "Duplicate Videos")
        case .largeVideos: String(localized: "Large Videos")
        case .livePhotos: String(localized: "Live Photos")
        }
    }

    var systemImage: String {
        switch self {
        case .duplicates: "square.on.square"
        case .bursts: "square.stack.3d.up"
        case .similar: "square.stack.3d.down.right"
        case .blurry: "camera.filters"
        case .unimportant: "photo.badge.minus"
        case .dark: "moon.zzz"
        case .screenshots: "camera.viewfinder"
        case .screenRecordings: "record.circle"
        case .duplicateVideos: "film.stack"
        case .largeVideos: "film"
        case .livePhotos: "livephoto"
        }
    }

    var explanation: String {
        switch self {
        case .duplicates:
            String(
                localized:
                    "Copies of the same photo. We keep one of each and select the rest for removal."
            )
        case .bursts:
            String(localized: "Several frames of one moment. Keep the best, remove the rest.")
        case .similar:
            String(
                localized:
                    "Several shots of the same moment. We keep the best one and select the rest for removal."
            )
        case .dark:
            String(localized: "Photos with nothing in them: pocket shots and lens caps.")
        case .screenRecordings:
            String(localized: "Screen recordings, newest first.")
        case .livePhotos:
            String(
                localized: "Live Photos whose motion you never play. Keep the still, drop the movie.")
        case .blurry:
            String(
                localized:
                    "Photos that look out of focus or shaken. All are selected for removal. Deselect any you want to keep."
            )
        case .unimportant:
            String(
                localized:
                    "Shaky photos with no people that you probably never look at. Nothing is selected for you."
            )
        case .screenshots:
            String(
                localized:
                    "All your screenshots, newest first. All are selected for removal. Deselect any you want to keep."
            )
        case .duplicateVideos:
            String(
                localized:
                    "Copies of the same video. We keep one of each and select the rest for removal."
            )
        case .largeVideos:
            String(localized: "Your biggest videos, largest first. Nothing is selected for you.")
        }
    }
}

extension ResultLevel {
    /// The words for a level in a category with levels (spec 011).
    func title(for category: CleanupCategory) -> String {
        switch (category, self) {
        case (.unimportant, .tight): String(localized: "Most likely")
        case (.unimportant, .medium): String(localized: "Probably")
        case (.unimportant, .wide): String(localized: "Maybe")
        case (_, .tight): String(localized: "Almost identical")
        case (_, .medium): String(localized: "Same shot")
        case (_, .wide): String(localized: "Same scene")
        }
    }
}

extension DateReason {
    /// A short note about why a copy's date or details look less reliable.
    var explanation: String {
        switch self {
        case .missing: String(localized: "This copy has no date.")
        case .placeholder:
            String(localized: "This date looks like a placeholder, not when it was taken.")
        case .inFuture: String(localized: "This date is in the future.")
        case .savedDate: String(localized: "Dated when it was saved, not when it was taken.")
        case .sharedStamp:
            String(localized: "Many photos share this exact date, probably an import.")
        case .midnight: String(localized: "This date has no time of day.")
        case .strippedLocation: String(localized: "No location. Another copy has one.")
        }
    }
}
