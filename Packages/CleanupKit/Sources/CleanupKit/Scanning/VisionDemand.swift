import Foundation

/// Which photos can use the Vision requests, computed from the whole library (spec 010).
///
/// `SimilarShotsDetector` compares the feature prints of two photos only when they are at most
/// `SimilarThresholds.window` apart, and `KeeperRules.similarKeepers` reads face quality only for
/// members of a similar-shots group, which joins photos by such a pair or by a shared burst. A photo
/// with no other photo within the window and no burst can be in no group, so neither request is of
/// any use for it. The library is a superset of the photos any detector receives (a neighbour whose
/// analysis fails, or that an earlier category takes away, still counts), so the answer is never
/// less than what a detector reads.
struct VisionDemand: Sendable {
    /// Capture dates, as seconds since the reference date, of every photo and live photo, ascending.
    /// Photos without a capture date have no neighbours and are left out.
    private let dates: [Double]

    init(library: [AssetMetadata]) {
        dates =
            library
            .compactMap {
                Self.isGroupable($0.kind) ? $0.captureDate?.timeIntervalSinceReferenceDate : nil
            }
            .sorted()
    }

    /// Whether `SimilarShotsDetector` can see a photo of this kind. Videos and screenshots never reach it.
    static func isGroupable(_ kind: ItemKind) -> Bool { kind == .photo || kind == .livePhoto }

    /// The Vision work some detector can read for this photo.
    func work(for m: AssetMetadata) -> VisionWork {
        guard Self.isGroupable(m.kind) else { return [] }
        if hasNeighbour(m) { return .all }
        return m.burstID != nil ? .faceQuality : []
    }

    /// The work to skip for this photo: the rest of `VisionWork.all`.
    func skipped(for m: AssetMetadata) -> VisionWork { VisionWork.all.subtracting(work(for: m)) }

    /// Whether another photo is within the similar-shots window: the same test the detector makes,
    /// `later.timeIntervalSince(earlier) <= window`, on the same doubles. `m` must be a member of the
    /// library this was made from: it is counted once among the photos in the window, so a second one
    /// is its neighbour.
    private func hasNeighbour(_ m: AssetMetadata) -> Bool {
        guard let date = m.captureDate?.timeIntervalSinceReferenceDate else { return false }
        let window = SimilarThresholds.window
        let first = partition { date - $0 <= window }
        let end = partition { $0 - date > window }
        return end - first >= 2
    }

    /// The first index whose value satisfies `predicate`, in an array on which it is false and then
    /// true.
    private func partition(_ predicate: (Double) -> Bool) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(dates[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
