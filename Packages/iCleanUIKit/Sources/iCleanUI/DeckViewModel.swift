#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import ScanEngine
import ProposalStore

/// The deck contract (SCAN_PIPELINE.md §12): the view model owns an immutable
/// DEALT WINDOW (top card + 5-card buffer); observation diffs apply only
/// behind the window, so a card never mutates on screen. Verdicts are
/// compare-and-set; losing the race to invalidation completes the gesture
/// visually, discards the verdict, and shows a quiet toast.
@MainActor
public final class DeckViewModel: ObservableObject {
    public static let dealtWindowSize = 6 // top card + 5-card prefetch buffer

    @Published public private(set) var dealtCards: [ProposalCard] = []
    @Published public private(set) var stagingTotals = StagingTotals(count: 0, bytes: 0)
    @Published public var toast: String?
    @Published public private(set) var isDeckEmpty = false

    public let family: Family

    private let store: DeckStore
    private var backlog: [ProposalCard] = []
    private var observationCancellable: AnyObject?
    private var totalsCancellable: AnyObject?

    public init(family: Family, store: DeckStore) {
        self.family = family
        self.store = store
        startObserving()
    }

    private func startObserving() {
        observationCancellable = store.observePendingWindow(family: family) { [weak self] cards in
            Task { @MainActor in
                self?.applyWindowUpdate(cards)
            }
        }
        totalsCancellable = store.observeStagingTotals { [weak self] totals in
            Task { @MainActor in
                self?.stagingTotals = totals
            }
        }
    }

    private func applyWindowUpdate(_ cards: [ProposalCard]) {
        let dealtIds = Set(dealtCards.map(\.id))
        // Diffs only behind the window: new/changed cards refresh the backlog;
        // the dealt cards are untouched until swiped.
        backlog = cards.filter { !dealtIds.contains($0.id) }
        refill()
        isDeckEmpty = dealtCards.isEmpty && backlog.isEmpty
    }

    private func refill() {
        while dealtCards.count < Self.dealtWindowSize, !backlog.isEmpty {
            let card = backlog.removeFirst()
            dealtCards.append(card)
            try? store.markShown(id: card.id) // impression semantics
        }
    }

    public var topCard: ProposalCard? { dealtCards.first }

    // MARK: - Verdicts

    public func swipeRight() {
        guard let card = topCard else { return }
        advance()
        do {
            if try store.approve(id: card.id) == .invalidatedMidSwipe {
                toast = "That group changed — skipped"
            }
        } catch {
            toast = "Couldn't queue that one"
        }
    }

    public func swipeLeft() {
        guard let card = topCard else { return }
        advance()
        do {
            if try store.reject(id: card.id) == .invalidatedMidSwipe {
                toast = "That group changed — skipped"
            }
        } catch {
            toast = "Couldn't save that choice"
        }
    }

    /// Swipe-down: pop the undo stack; the reverted card returns to the deck top.
    public func undo() {
        guard let revertedId = try? store.undoLast() else { return }
        if let index = backlog.firstIndex(where: { $0.id == revertedId }) {
            let card = backlog.remove(at: index)
            dealtCards.insert(card, at: 0)
        }
        // If it isn't in the backlog yet, the observation refresh will surface it.
    }

    private func advance() {
        guard !dealtCards.isEmpty else { return }
        dealtCards.removeFirst()
        refill()
        isDeckEmpty = dealtCards.isEmpty && backlog.isEmpty
    }
}

public func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
#endif
