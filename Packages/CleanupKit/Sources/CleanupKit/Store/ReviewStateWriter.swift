import Foundation

/// Saves the person's review choices and position shortly after they change, and on demand.
///
/// A change is saved after `debounce` of quiet, and at the latest `maxWait` after the first
/// unsaved change, so a burst of taps is one write and a long burst is still written. `flush()`
/// writes at once and returns when it is done: it is what runs when the app goes inactive or to the
/// background, when the confirm sheet opens, and before a removal. Nothing depends on the app being
/// told it is about to be killed, because it is not told.
///
/// `invalidate()` makes Delete All Data safe: it cancels what is pending, waits for a write already
/// under way, and refuses anything handed in before it, so nothing the person deleted is written back.
public actor ReviewStateWriter {
    private let store: any Store
    private let debounce: Duration
    private let maxWait: Duration
    private var generation = 0
    private var pendingDecisions: ReviewIntent?
    private var pendingPosition: ReviewPosition?
    private var firstDirty: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?
    private(set) public var failedWrites = 0

    public init(
        store: any Store, debounce: Duration = .milliseconds(500), maxWait: Duration = .seconds(2)
    ) {
        self.store = store
        self.debounce = debounce
        self.maxWait = maxWait
    }

    /// Records the newest values and schedules a write. `generation` is the one the caller read
    /// from `currentGeneration()`; a stale one is refused (see `invalidate`).
    public func update(
        decisions: ReviewIntent? = nil, position: ReviewPosition? = nil, generation g: Int
    ) {
        guard g == generation else { return }
        if let decisions { pendingDecisions = decisions }
        if let position { pendingPosition = position }
        guard pendingDecisions != nil || pendingPosition != nil else { return }
        let now = ContinuousClock.now
        let started = firstDirty ?? now
        firstDirty = started
        let waitLeft = maxWait - (now - started)
        let wait = min(debounce, max(.zero, waitLeft))
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func currentGeneration() -> Int { generation }

    /// Writes everything pending now and returns when it is written.
    public func flush() async {
        timer?.cancel()
        timer = nil
        // Wait for a write under way first, so two writes never overtake each other.
        await inFlight?.value
        let decisions = pendingDecisions
        let position = pendingPosition
        pendingDecisions = nil
        pendingPosition = nil
        firstDirty = nil
        guard decisions != nil || position != nil else { return }
        let g = generation
        let store = self.store
        let task = Task { [weak self] in
            var failed = false
            if let decisions, let data = try? StateCodec.seal(decisions) {
                do {
                    try await store.saveState(
                        .decisions, version: ReviewIntent.formatVersion, payload: data)
                } catch { failed = true }
            }
            if let position, let data = try? StateCodec.seal(position) {
                do {
                    try await store.saveState(
                        .position, version: ReviewPosition.formatVersion, payload: data)
                } catch { failed = true }
            }
            if failed { await self?.noteFailure(generation: g) }
        }
        inFlight = task
        await task.value
    }

    private func noteFailure(generation g: Int) {
        guard g == generation else { return }
        failedWrites += 1
    }

    /// Drops everything pending, waits for a write under way, and refuses older updates from now on.
    public func invalidate() async {
        generation += 1
        timer?.cancel()
        timer = nil
        pendingDecisions = nil
        pendingPosition = nil
        firstDirty = nil
        await inFlight?.value
    }
}
