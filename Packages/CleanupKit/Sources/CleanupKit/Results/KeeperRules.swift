import Foundation

/// Which items to suggest keeping in a group (FR-008).
public enum KeeperRules {
    /// Duplicates: every favorite; otherwise the highest resolution, then the best
    /// file quality (largest file), and if still tied, the oldest.
    public static func duplicateKeepers(_ items: [LibraryItem]) -> Set<String> {
        let favorites = items.filter { $0.metadata.isFavorite }
        if !favorites.isEmpty { return Set(favorites.map(\.assetID)) }
        guard let best = items.min(by: duplicateOrder) else { return [] }
        return [best.assetID]
    }

    /// Similar shots: every favorite; otherwise the sharpest, with face capture
    /// quality breaking near-ties (sharpness within 0.02).
    public static func similarKeepers(_ items: [LibraryItem]) -> Set<String> {
        let favorites = items.filter { $0.metadata.isFavorite }
        if !favorites.isEmpty { return Set(favorites.map(\.assetID)) }
        guard let best = items.min(by: similarOrder) else { return [] }
        return [best.assetID]
    }

    static func similarOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        let sa = a.analysis?.sharpness ?? 0
        let sb = b.analysis?.sharpness ?? 0
        if abs(sa - sb) > 0.02 { return sa > sb }
        let fa = a.analysis?.faceQuality ?? -1
        let fb = b.analysis?.faceQuality ?? -1
        if fa != fb { return fa > fb }
        if sa != sb { return sa > sb }
        return a.assetID < b.assetID
    }

    /// Strict ordering: true when `a` is a better keeper than `b`.
    static func duplicateOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        if a.metadata.pixelCount != b.metadata.pixelCount {
            return a.metadata.pixelCount > b.metadata.pixelCount
        }
        if a.effectiveByteSize != b.effectiveByteSize {
            return a.effectiveByteSize > b.effectiveByteSize
        }
        let da = a.metadata.captureDate ?? .distantFuture
        let db = b.metadata.captureDate ?? .distantFuture
        if da != db { return da < db }
        return a.assetID < b.assetID
    }

    /// Display order for a group: keepers first, then the rest by date.
    static func ordered(_ items: [LibraryItem], keepers: Set<String>) -> [String] {
        items.sorted { a, b in
            let ka = keepers.contains(a.assetID)
            let kb = keepers.contains(b.assetID)
            if ka != kb { return ka }
            let da = a.metadata.captureDate ?? .distantFuture
            let db = b.metadata.captureDate ?? .distantFuture
            return da == db ? a.assetID < b.assetID : da < db
        }.map(\.assetID)
    }
}
