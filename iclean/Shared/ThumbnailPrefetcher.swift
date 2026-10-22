import CleanupKit
import Foundation
import Observation

/// Warms the pictures of a list a little ahead of the scroll, in the direction it is moving, and
/// lets go of the ones it has left behind: the standard remedy for jerky scrolling through a long
/// list of photos. Cells report when they appear and disappear; the rule for how far ahead is
/// `PrefetchWindow`.
@MainActor @Observable
final class ThumbnailPrefetcher {
    @ObservationIgnored private var library: PhotoLibrary?
    @ObservationIgnored private var pixelSize = 300
    /// Everything in the list, in the order it is shown, and where each one is.
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var position: [String: Int] = [:]
    /// Tracked by id, not by place, because a scan keeps changing the list.
    @ObservationIgnored private var onScreen: Set<String> = []
    @ObservationIgnored private var warm: Set<String> = []
    @ObservationIgnored private var lastCentre: Double?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private let window = PrefetchWindow()

    /// The list to prefetch for, in the order it is shown. Cheap to call again when it has not changed.
    func use(library: PhotoLibrary, ids: [String], pixelSize: Int) {
        self.library = library
        guard ids != order || pixelSize != self.pixelSize else { return }
        if pixelSize != self.pixelSize { stopAll() }
        self.pixelSize = pixelSize
        order = ids
        position = Dictionary(
            ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        scheduleRefresh()
    }

    func appeared(_ assetID: String) {
        onScreen.insert(assetID)
        scheduleRefresh()
    }

    func disappeared(_ assetID: String) {
        onScreen.remove(assetID)
        scheduleRefresh()
    }

    /// The screen is gone: let go of everything.
    func stopAll() {
        refreshTask?.cancel()
        refreshTask = nil
        if let library, !warm.isEmpty {
            library.stopPrefetching(Array(warm), pixelSize: pixelSize, fit: .fill)
        }
        warm = []
        onScreen = []
        lastCentre = nil
    }

    /// A burst of appear and disappear events while scrolling is one refresh.
    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func refresh() {
        refreshTask = nil
        guard let library, !order.isEmpty else { return }
        let places = onScreen.compactMap { position[$0] }
        guard let low = places.min(), let high = places.max() else { return }
        let centre = Double(low + high) / 2
        let direction: PrefetchWindow.Direction =
            lastCentre.map {
                centre > $0 + 0.5 ? .forward : (centre < $0 - 0.5 ? .backward : .idle)
            }
            ?? .idle
        lastCentre = centre
        guard let range = window.warm(visible: low...high, direction: direction, count: order.count)
        else { return }

        let wanted = order[range]
        let wantedSet = Set(wanted)
        // Nearest first in the direction of travel, so the cells about to arrive come first.
        let toStart = wanted.filter { !warm.contains($0) }
        let toStop = warm.subtracting(wantedSet)
        warm = wantedSet
        if !toStart.isEmpty {
            let ordered = direction == .backward ? Array(toStart.reversed()) : Array(toStart)
            library.startPrefetching(ordered, pixelSize: pixelSize, fit: .fill)
        }
        if !toStop.isEmpty {
            library.stopPrefetching(Array(toStop), pixelSize: pixelSize, fit: .fill)
        }
    }
}
