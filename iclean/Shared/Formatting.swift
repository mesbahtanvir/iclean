import CleanupKit
import Foundation

enum Format {
    static func bytes(_ bytes: Int64, estimate: Bool) -> String {
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return estimate ? String(localized: "about \(text)") : text
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? ""
    }
}

extension CleanupCategory {
    var title: String {
        switch self {
        case .duplicates: String(localized: "Duplicates")
        case .similar: String(localized: "Similar Shots")
        case .blurry: String(localized: "Blurry")
        case .screenshots: String(localized: "Screenshots")
        case .duplicateVideos: String(localized: "Duplicate Videos")
        case .largeVideos: String(localized: "Large Videos")
        }
    }

    var systemImage: String {
        switch self {
        case .duplicates: "square.on.square"
        case .similar: "square.stack.3d.down.right"
        case .blurry: "camera.metering.unknown"
        case .screenshots: "camera.viewfinder"
        case .duplicateVideos: "film.stack"
        case .largeVideos: "film"
        }
    }

    var explanation: String {
        switch self {
        case .duplicates: String(localized: "Copies of the same photo. One copy of each is kept.")
        case .similar: String(localized: "Several shots of the same moment. The best one is kept.")
        case .blurry: String(localized: "Photos that look out of focus or shaken.")
        case .screenshots: String(localized: "All your screenshots, newest first.")
        case .duplicateVideos:
            String(localized: "Copies of the same video. One copy of each is kept.")
        case .largeVideos: String(localized: "Your 50 biggest videos. Nothing is selected for you.")
        }
    }
}

extension DateReason {
    /// A short note about why a copy's date or details look less reliable.
    var explanation: String {
        switch self {
        case .missing: String(localized: "This copy has no date.")
        case .placeholder: String(localized: "This date looks like a default (1970, 2001 or 1904).")
        case .inFuture: String(localized: "This date has not happened yet.")
        case .savedDate: String(localized: "Dated when it was saved, not when it was taken.")
        case .sharedStamp:
            String(localized: "Many photos share this exact date, probably an import.")
        case .midnight: String(localized: "This date has no time of day.")
        case .strippedLocation: String(localized: "No location. Another copy has one.")
        }
    }
}
