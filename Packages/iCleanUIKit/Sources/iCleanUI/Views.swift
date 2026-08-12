#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import ScanEngine
import ProposalStore
import CommitEngine

// MARK: - Image loading seam (the app injects a PHCachingImageManager-backed
// loader; iCleanUI never imports Photos — APP_PLATFORM.md §1)

public protocol CardImageLoading: Sendable {
    /// Best local image for display (never triggers iCloud downloads).
    func image(assetId: String, maxDimension: Int) async -> Image?
}

private struct ImageLoaderKey: EnvironmentKey {
    static let defaultValue: (any CardImageLoading)? = nil
}

public extension EnvironmentValues {
    var cardImageLoader: (any CardImageLoading)? {
        get { self[ImageLoaderKey.self] }
        set { self[ImageLoaderKey.self] = newValue }
    }
}

public struct AssetThumbnailView: View {
    @Environment(\.cardImageLoader) private var loader
    let assetId: String
    let maxDimension: Int
    @State private var image: Image?

    public init(assetId: String, maxDimension: Int = 512) {
        self.assetId = assetId
        self.maxDimension = maxDimension
    }

    public var body: some View {
        ZStack {
            if let image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary) // shimmer placeholder
            }
        }
        .task(id: assetId) {
            image = await loader?.image(assetId: assetId, maxDimension: maxDimension)
        }
    }
}

// MARK: - Home ("Today" — DESIGN.md §10)

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public var summaries: [Family: StagingTotals] = [:]
    @Published public var staging = StagingTotals(count: 0, bytes: 0)

    private let store: DeckStore
    private var totalsCancellable: AnyObject?

    public init(store: DeckStore) {
        self.store = store
        refresh()
        totalsCancellable = store.observeStagingTotals { [weak self] totals in
            Task { @MainActor in self?.staging = totals }
        }
    }

    public func refresh() {
        summaries = (try? store.familySummaries()) ?? [:]
    }

    public var reclaimableBytes: Int64 {
        summaries.values.reduce(0) { $0 + $1.bytes }
    }
}

public struct HomeView: View {
    @ObservedObject var model: HomeViewModel
    let onOpenFamily: (Family) -> Void
    let onOpenBin: () -> Void

    public init(model: HomeViewModel, onOpenFamily: @escaping (Family) -> Void, onOpenBin: @escaping () -> Void) {
        self.model = model
        self.onOpenFamily = onOpenFamily
        self.onOpenBin = onOpenBin
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                storageHeader
                pilesGrid
                trustFooter
            }
            .padding()
        }
        .navigationTitle("iClean")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onOpenBin) {
                    Label(formatBytes(model.staging.bytes), systemImage: "tray.full")
                }
                .disabled(model.staging.count == 0)
            }
        }
        .onAppear { model.refresh() }
    }

    private var storageHeader: some View {
        VStack(spacing: 4) {
            Text(formatBytes(model.reclaimableBytes))
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text("ready to review")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var pilesGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(Family.allCases, id: \.self) { family in
                let totals = model.summaries[family] ?? StagingTotals(count: 0, bytes: 0)
                Button {
                    onOpenFamily(family)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(familyTitle(family)).font(.headline)
                        Text("\(totals.count) items")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(formatBytes(totals.bytes))
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .disabled(totals.count == 0)
                .opacity(totals.count == 0 ? 0.5 : 1) // greyed until the bucket unlocks
            }
        }
    }

    private var trustFooter: some View {
        Text("Everything goes to Recently Deleted. 30 days to undo.\nNothing leaves your phone. Free first cleanup · $2.99 once.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 12)
    }
}

func familyTitle(_ family: Family) -> String {
    switch family {
    case .duplicates: return "Duplicates"
    case .similar: return "Similar"
    case .junk: return "Blurry & Junk"
    case .screenshots: return "Screenshots"
    }
}

// MARK: - The deck (DESIGN.md §8 gestures: left = keep, right = clean,
// up = inspect/edit, down = undo)

public struct DeckView: View {
    @ObservedObject var model: DeckViewModel
    @State private var dragOffset: CGSize = .zero
    @State private var editingCard: ProposalCard?

    public init(model: DeckViewModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            if model.isDeckEmpty {
                emptyState
            } else {
                cardStack
            }
            toastOverlay
        }
        .navigationTitle(familyTitle(model.family))
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    Spacer()
                    Text("\(formatBytes(model.stagingTotals.bytes)) queued")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $editingCard) { card in
            ClusterEditGrid(card: card) { keepIds in
                // Rescues: everything not kept follows the swipe verdict.
                editingCard = nil
                if keepIds.count == card.memberIds.count {
                    model.swipeLeft() // keep all = reject
                } else {
                    model.swipeRight()
                }
            }
        }
    }

    private var cardStack: some View {
        ZStack {
            // Render up to 3 cards for depth; only the top is interactive.
            ForEach(Array(model.dealtCards.prefix(3).enumerated().reversed()), id: \.element.id) { index, card in
                ProposalCardView(card: card)
                    .scaleEffect(1.0 - Double(index) * 0.04)
                    .offset(y: Double(index) * 10)
                    .offset(index == 0 ? dragOffset : .zero)
                    .rotationEffect(.degrees(index == 0 ? Double(dragOffset.width / 24) : 0))
                    .gesture(index == 0 ? dragGesture : nil)
            }
        }
        .padding()
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                withAnimation(.spring(duration: 0.3)) { dragOffset = .zero }
                if abs(horizontal) > 90, abs(horizontal) > abs(vertical) {
                    if horizontal > 0 { model.swipeRight() } else { model.swipeLeft() }
                } else if vertical < -90 {
                    editingCard = model.topCard // up = inspect / edit the proposal
                } else if vertical > 90 {
                    model.undo() // down = take it back
                }
            }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle").font(.system(size: 48))
            Text("\(familyTitle(model.family)): done").font(.title3.weight(.semibold))
            Text("\(formatBytes(model.stagingTotals.bytes)) queued so far")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 60)
                .task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    model.toast = nil
                }
        }
    }
}

public struct ProposalCardView: View {
    let card: ProposalCard

    public init(card: ProposalCard) {
        self.card = card
    }

    public var body: some View {
        VStack(spacing: 0) {
            heroImage
            footer
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .shadow(radius: 8, y: 4)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let keeper = card.keeperId {
            VStack(spacing: 4) {
                AssetThumbnailView(assetId: keeper)
                    .overlay(alignment: .topLeading) {
                        Label("KEEP", systemImage: "star.fill")
                            .font(.caption.bold())
                            .padding(6)
                            .background(.yellow, in: Capsule())
                            .padding(8)
                    }
                filmstrip
            }
        } else if let first = card.memberIds.first {
            AssetThumbnailView(assetId: first)
        }
    }

    @ViewBuilder
    private var filmstrip: some View {
        // The deletions get the inspectable thumbnails — the scary part is
        // what leaves (DESIGN.md §9.1 Tier 3).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(card.memberIds, id: \.self) { id in
                    AssetThumbnailView(assetId: id, maxDimension: 160)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 92)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text(card.reasonText)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
            HStack {
                Label("Keep", systemImage: "arrow.left")
                Spacer()
                Text(formatBytes(card.estBytes)).font(.caption.monospacedDigit())
                Spacer()
                Label("Clean", systemImage: "arrow.right")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

// MARK: - Cluster edit grid ("keep 2 of 12" — DESIGN.md §8)

public struct ClusterEditGrid: View {
    let card: ProposalCard
    let onApply: (Set<String>) -> Void
    @State private var keptIds: Set<String> = []

    public init(card: ProposalCard, onApply: @escaping (Set<String>) -> Void) {
        self.card = card
        self.onApply = onApply
        _keptIds = State(initialValue: card.keeperId.map { [$0] } ?? [])
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                    ForEach(allIds, id: \.self) { id in
                        AssetThumbnailView(assetId: id, maxDimension: 256)
                            .frame(height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: keptIds.contains(id) ? "star.fill" : "trash")
                                    .foregroundStyle(keptIds.contains(id) ? .yellow : .red)
                                    .padding(6)
                                    .background(.thinMaterial, in: Circle())
                                    .padding(4)
                            }
                            .onTapGesture { toggle(id) }
                    }
                }
                .padding()
            }
            .navigationTitle("Keep \(keptIds.count), remove \(allIds.count - keptIds.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Keep all") { onApply(Set(allIds)) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { onApply(keptIds) }
                        .disabled(keptIds.isEmpty)
                }
            }
        }
    }

    private var allIds: [String] {
        var ids = card.memberIds
        if let keeper = card.keeperId, !ids.contains(keeper) {
            ids.insert(keeper, at: 0)
        }
        return ids
    }

    private func toggle(_ id: String) {
        if keptIds.contains(id) { keptIds.remove(id) } else { keptIds.insert(id) }
    }
}

// MARK: - Review & Commit (DESIGN.md §9.2 net 3, APP_PLATFORM.md §2)

@MainActor
public final class CommitViewModel: ObservableObject {
    @Published public var groups: [(actionType: ActionType, cards: [ProposalCard])] = []
    @Published public var totals = StagingTotals(count: 0, bytes: 0)
    @Published public var chunkCount = 0
    @Published public var outcome: CommitRunner.Outcome?
    @Published public var isCommitting = false

    private let store: DeckStore
    private let runner: CommitRunner

    public init(store: DeckStore, runner: CommitRunner) {
        self.store = store
        self.runner = runner
        refresh()
    }

    public func refresh() {
        groups = (try? store.stagedByAction()) ?? []
        totals = (try? store.stagingTotals()) ?? StagingTotals(count: 0, bytes: 0)
        Task {
            chunkCount = (try? await runner.plannedChunkCount()) ?? 0
        }
    }

    public func restore(id: Int64) {
        try? store.restoreFromBin(id: id)
        refresh()
    }

    public func commit() {
        isCommitting = true
        Task {
            defer { isCommitting = false }
            outcome = try? await runner.commitStaged()
            refresh()
            try? store.writeWidgetSnapshot()
        }
    }
}

public struct CommitReviewView: View {
    @ObservedObject var model: CommitViewModel

    public init(model: CommitViewModel) {
        self.model = model
    }

    public var body: some View {
        List {
            if model.chunkCount > 1 {
                // Honesty first: the one-dialog promise is per-chunk (DESIGN.md §3).
                Section {
                    Label("iOS will ask you to confirm \(model.chunkCount) times", systemImage: "info.circle")
                        .font(.callout)
                }
            }
            ForEach(model.groups, id: \.actionType) { group in
                Section(familyTitle(group.actionType.family)) {
                    ForEach(group.cards) { card in
                        HStack {
                            AssetThumbnailView(assetId: card.memberIds.first ?? "", maxDimension: 120)
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading) {
                                Text(card.reasonText).font(.callout).lineLimit(1)
                                Text("\(card.memberIds.count) item(s) · \(formatBytes(card.estBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Restore") { model.restore(id: card.id) }
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Review & Clean")
        .safeAreaInset(edge: .bottom) {
            commitButton
        }
        .sheet(item: Binding(
            get: { model.outcome.map(OutcomeBox.init) },
            set: { _ in model.outcome = nil }
        )) { box in
            SummaryView(outcome: box.outcome)
        }
        .onAppear { model.refresh() }
    }

    private var commitButton: some View {
        Button {
            model.commit()
        } label: {
            Text("Move \(model.totals.count) items to Recently Deleted")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.totals.count == 0 || model.isCommitting)
        .padding()
        .background(.thinMaterial)
    }
}

private struct OutcomeBox: Identifiable {
    let outcome: CommitRunner.Outcome
    var id: Int { outcome.deletedCount }
}

public struct SummaryView: View {
    let outcome: CommitRunner.Outcome

    public init(outcome: CommitRunner.Outcome) {
        self.outcome = outcome
    }

    public var body: some View {
        VStack(spacing: 14) {
            Image(systemName: outcome.cancelled ? "hand.raised" : "checkmark.seal.fill")
                .font(.system(size: 52))
                .foregroundStyle(outcome.cancelled ? .orange : .green)
            if outcome.cancelled {
                Text("No changes made").font(.title2.bold())
                Text("Your staged decisions are safe — commit whenever you're ready.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            } else {
                Text("\(outcome.deletedCount) items cleaned").font(.title2.bold())
                Text("\(outcome.bytesAreEstimates ? "~" : "")\(formatBytes(outcome.confirmedBytes)) queued for reclaim")
                    .font(.headline)
                // Recently Deleted honesty (DESIGN.md §9.2 net 4): no deep link
                // exists — illustrated steps, at least 30 days.
                Text("Recoverable in Photos → Albums → Utilities → Recently Deleted for at least 30 days. Empty it there to free space immediately.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if outcome.heldByPaywall > 0 {
                    Text("\(outcome.heldByPaywall) items are staged and waiting — unlock unlimited cleaning for $2.99, once.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(28)
    }
}
#endif
