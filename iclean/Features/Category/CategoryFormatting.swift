import CleanupKit
import Foundation

/// Small helpers the category, compare and viewer screens share (spec 011 6.5 to 6.8).

extension Format {
    /// "4,032 × 3,024 · 3.2 MB", with the length of a video at the end ("· 0:12").
    static func facts(of item: LibraryItem) -> String {
        let m = item.metadata
        let size = bytes(item.effectiveByteSize, estimate: item.sizeIsEstimate)
        // Numbers are grouped here ("4,032"): a String interpolation of an Int is not.
        let width = m.pixelWidth.formatted()
        let height = m.pixelHeight.formatted()
        var text = String(localized: "\(width) × \(height) · \(size)")
        if let length = m.duration { text += " · " + duration(length) }
        return text
    }

    /// "Nov 14, 2023 at 5:13 PM".
    static func capture(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

extension ItemKind {
    /// The word VoiceOver starts a description with.
    var spokenName: String {
        switch self {
        case .photo: String(localized: "Photo")
        case .screenshot: String(localized: "Screenshot")
        case .livePhoto: String(localized: "Live Photo")
        case .video: String(localized: "Video")
        }
    }
}

extension CGFloat {
    /// This value held between two limits.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Whether the person is looking at the state "selected for removal" or "staying", in the words
/// every screen and every VoiceOver value uses.
enum ReviewState {
    static func text(selected: Bool) -> String {
        selected
            ? String(localized: "Selected for removal")
            : String(localized: "Staying in your library")
    }
}
