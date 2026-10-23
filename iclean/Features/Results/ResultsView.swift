import CleanupKit
import SwiftUI

/// Home when there is something to show: the hero (how much can be freed), the scan status while a
/// scan runs, the categories, and the one next step pinned at the bottom (spec 012 section 6.3).
///
/// Everything here reads the cached `model.summary`. Nothing reads the scan's progress (only the
/// status card does), so a progress tick never re-evaluates the rows, and no photo file is read.
struct ResultsView: View {
    /// The Review bar asks the host to open the Confirm sheet; the host owns the sheet.
    let onReview: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let hasResults = !model.results.categories.isEmpty
        let hasSelection = model.summary.count > 0
        // The summary is worked out a moment after the results arrive. Until then there is no
        // number to give, and "Nothing selected yet" would be a claim, so the hero waits for it.
        let summaryReady = !model.summary.perCategory.isEmpty
        let idle = !model.isScanning && !model.isFinishing && !model.hasInterruptedScan
        List {
            if hasResults && summaryReady { heroSection }
            if model.isScanning {
                Section { ScanningView() }
            } else if model.hasInterruptedScan {
                resumeSection
            }
            if !model.continueRoute.isEmpty { ContinueSection() }
            if model.pendingNewCount > 0 { showNewSection }
            if hasResults {
                categorySection
            } else if !model.isScanning && (model.isBuildingResults || model.isFinishing) {
                // Never while the scan runs: with nothing found yet, the card is the only row and
                // the results area stays silent.
                updatingSection
            }
            footerSection(
                showsScanAgain: idle,
                // At accessibility sizes the reassurance joins the list so the pinned bar stays one
                // button tall.
                showsReviewNote: hasSelection && typeSize.isAccessibilitySize)
        }
        #if os(iOS)
            .listStyle(.insetGrouped)
        #endif
        .readableColumn()
        .pinnedBar(isPresented: hasSelection) {
            ReviewBar(
                summary: model.summary, showsNote: !typeSize.isAccessibilitySize, action: onReview)
        }
        .calmAnimation(value: hasSelection)
    }

    // MARK: Sections

    /// The hero in a card of its own, with the storage bar under the figure once there is a
    /// selection to split (spec 013). The bar is decoration, and the first thing to go when text is
    /// large: the rows must stay clear of the pinned Review bar.
    private var heroSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Space.m) {
                HomeHero(summary: model.summary, isScanning: model.isScanning)
                if model.summary.count > 0, !typeSize.isAccessibilitySize {
                    StorageBar(perCategory: model.summary.perCategory)
                }
            }
        }
    }

    /// An interrupted scan with results: the way to carry on is the top row, and "Scan Again" is
    /// not offered beside it.
    private var resumeSection: some View {
        Section { ResumeScanRow() }
    }

    private var showNewSection: some View {
        Section { ShowNewItemsRow() }
    }

    @ViewBuilder private var categorySection: some View {
        if model.isScanning {
            // These are the finds so far; the scan is still going (004 FR-009).
            Section {
                categoryRows
            } header: {
                Text("Found so far")
                    .accessibilityIdentifier("results.foundSoFar")
            }
        } else {
            Section { categoryRows }
        }
    }

    /// Rows keep the categories' fixed order, so they never reshuffle under a finger.
    private var categoryRows: some View {
        ForEach(model.results.categories) { result in
            NavigationLink(value: Route.category(result.category)) {
                CategoryRow(category: result.category)
            }
            .accessibilityIdentifier("results.category.\(result.category.rawValue)")
        }
    }

    private var updatingSection: some View {
        Section {
            DelayedProgress(caption: "Updating results…")
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("results.updating")
                .quietRow()
        }
    }

    /// The periphery, last: what was not checked, when it was, and the notices.
    @ViewBuilder private func footerSection(showsScanAgain: Bool, showsReviewNote: Bool)
        -> some View
    {
        let notScanned = model.results.notScannedCount
        if notScanned > 0 || showsScanAgain || !HomeNotices.isEmpty(model) || showsReviewNote {
            Section {
                if notScanned > 0 { ICloudFootnote(count: notScanned).quietRow() }
                if showsScanAgain { ScanAgainLine().quietRow() }
                if !HomeNotices.isEmpty(model) { HomeNotices().quietRow() }
                if showsReviewNote { ReviewNote().quietRow() }
            }
        }
    }
}

/// "Resume Scan" over "Picks up where it stopped.": the way to carry on after an interrupted scan.
/// A row in Home's list on a phone, and in the sidebar footer on a Mac.
struct ResumeScanRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.startScan()
        } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Resume Scan")
                    .font(.headline)
                    .foregroundStyle(Palette.accentText)
                Text("Picks up where it stopped.")
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
            }
            .frame(maxWidth: .infinity, minHeight: Hit.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("home.resume")
    }
}

/// "Show 3 new items": newer results that were held back while the person was looking at a list.
struct ShowNewItemsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.showPendingResults()
        } label: {
            Label {
                Text("Show ^[\(model.pendingNewCount) new item](inflect: true)")
            } icon: {
                Image(systemName: "arrow.down.circle")
            }
            .labelStyle(.quiet)
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: Hit.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("results.showNew")
    }
}

extension View {
    /// A row that sits on the screen's background: no card, no separator.
    func quietRow(top: CGFloat = Space.s, bottom: CGFloat = Space.s) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(
                EdgeInsets(top: top, leading: Space.l, bottom: bottom, trailing: Space.l)
            )
            // In a list a Label puts its icon in a wide column; here the icon sits by the words.
            .labelStyle(.titleAndIcon)
    }
}

// MARK: Hero

/// How much can be freed, said once and large. Reads the selection summary, so it always agrees
/// with the Review button and the Confirm sheet. It is what the button will act on, never a sum of
/// category totals (Large Videos is never preselected).
struct HomeHero: View {
    let summary: SelectionSummary
    let isScanning: Bool

    var body: some View {
        Group {
            if summary.count == 0 {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Nothing selected yet")
                        .font(.title2.weight(.semibold))
                    Text("Open a category to choose what to remove.")
                        .font(.callout)
                        .foregroundStyle(Palette.quietText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            } else {
                HeroFigure(
                    overline: overline, value: Format.byteValue(summary.bytes), caption: caption,
                    spokenValue: SpokenBytes.string(summary.bytes))
            }
        }
        .accessibilityIdentifier("home.hero")
    }

    private var overline: String {
        switch (isScanning, summary.isEstimate) {
        case (false, false): String(localized: "You can free")
        case (false, true): String(localized: "You can free about")
        case (true, false): String(localized: "So far you can free")
        case (true, true): String(localized: "So far you can free about")
        }
    }

    private var caption: String {
        let count = summary.count
        return isScanning
            ? String(
                agreeing: AttributedString(
                    localized:
                        "from ^[\(count) item](inflect: true) selected so far. You choose what goes."
                ))
            : String(
                agreeing: AttributedString(
                    localized:
                        "from ^[\(count) selected item](inflect: true). You choose what goes."))
    }
}

// MARK: Rows

/// One category: what it is, how much of it is selected (in words), and how much space that is.
/// The figure is the size of what is selected, so it reconciles with the hero; when nothing is
/// selected it shows what could be removed, in secondary.
struct CategoryRow: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let tally = model.summary.perCategory[category]
        let detail = tally.map(Self.detail)
        let figure = tally.map(Self.figure)
        Group {
            if typeSize.isAccessibilitySize {
                // Stacked, so nothing is cut off at the largest sizes.
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.m) {
                        icon
                        title
                    }
                    if let detail { detailText(detail) }
                    if let figure { figureText(figure) }
                }
            } else {
                HStack(spacing: Space.m) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        if let detail { detailText(detail) }
                    }
                    Spacer(minLength: Space.m)
                    if let figure { figureText(figure) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(tally: tally, detail: detail))
    }

    /// The category's tile, in its colour (spec 013).
    private var icon: some View {
        CategoryIcon(category: category)
    }

    private var title: some View {
        Text(category.title).font(.body)
    }

    /// The words that say what is selected: decision text, so primary and not a footnote.
    private func detailText(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(.primary)
    }

    /// The size of what is selected; with nothing selected, "up to" the total that could be freed, so
    /// the two kinds of figure differ in words and not only in colour.
    @ViewBuilder private func figureText(_ figure: Figure) -> some View {
        if figure.isSelection {
            Text(Format.bytes(figure.bytes, estimate: figure.isEstimate))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        } else {
            Text("up to \(Format.byteValue(figure.bytes))")
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.quietText)
        }
    }

    /// "Duplicates, about 6.4 megabytes, All 3 selected", or with nothing selected "Large Videos,
    /// None selected, up to 933 megabytes could be freed": a figure first would sound like a selection.
    private func spokenLabel(tally: CategoryTally?, detail: String?) -> String {
        guard let tally, let detail else { return category.title }
        let figure = Self.figure(tally)
        let size = SpokenBytes.string(figure.bytes)
        if figure.isSelection {
            let spoken = SpokenBytes.string(figure.bytes, estimate: figure.isEstimate)
            return "\(category.title), \(spoken), \(detail)"
        }
        return String(localized: "\(category.title), \(detail), up to \(size) could be freed")
    }

    struct Figure {
        var bytes: Int64
        var isEstimate: Bool
        var isSelection: Bool
    }

    static func figure(_ tally: CategoryTally) -> Figure {
        tally.selected > 0
            ? Figure(
                bytes: tally.selectedBytes, isEstimate: tally.selectedIsEstimate, isSelection: true)
            : Figure(
                bytes: tally.removableBytes, isEstimate: tally.removableIsEstimate,
                isSelection: false)
    }

    /// "All 3 selected", "2 of 4 selected", "None selected"; for a single item "Selected" and
    /// "Not selected". When a keeper was chosen for removal too, only the count is said.
    static func detail(_ tally: CategoryTally) -> String {
        let selected = tally.selected
        let total = tally.removable
        if selected == 0 {
            return total == 1
                ? String(localized: "Not selected") : String(localized: "None selected")
        }
        guard selected == tally.selectedRemovable else {
            return String(localized: "\(selected) selected")
        }
        if selected == total {
            return total == 1
                ? String(localized: "Selected") : String(localized: "All \(total) selected")
        }
        return String(localized: "\(selected) of \(total) selected")
    }
}

/// The review that was open last time, offered when it was too old to open by itself.
private struct ContinueSection: View {
    var body: some View {
        Section { ContinueReviewingRow() }
    }
}

/// "Continue reviewing" over "Duplicates, 3 selected", and a dismiss button. A row in Home's list on
/// a phone, and in the sidebar footer on a Mac.
struct ContinueReviewingRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let category: CleanupCategory? = model.continueRoute.compactMap {
            if case .category(let c) = $0 { c } else { nil }
        }.first
        HStack(spacing: Space.s) {
            Button {
                model.continueReviewing()
            } label: {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Continue reviewing")
                        .font(.headline)
                        .foregroundStyle(Palette.accentText)
                    if let category {
                        Text("\(category.title), \(model.selectedCount(in: category)) selected")
                            .font(Typography.note)
                            .foregroundStyle(Palette.quietText)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Hit.minimum, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("home.continue")
            Button {
                model.dismissContinue()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: Hit.minimum, minHeight: Hit.minimum)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("home.continueDismiss")
        }
    }
}

// MARK: Scan Again

/// "Scanned 3 minutes ago" and the way to scan again, quietly. The text is drawn inside a timeline
/// that ticks once a minute, so it stays right without redrawing every second.
struct ScanAgainLine: View {
    /// Stacked even at normal sizes: the Mac sidebar is too narrow to hold both side by side.
    var stacked = false

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.everyMinute) { context in
            // Side by side normally; stacked at accessibility sizes.
            let stack = stacked || typeSize.isAccessibilitySize
            let layout =
                stack
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
                : AnyLayout(HStackLayout(spacing: Space.m))
            layout {
                scanned(at: context.date)
                if !stack { Spacer(minLength: Space.m) }
                scanButton
            }
        }
    }

    @ViewBuilder private func scanned(at now: Date) -> some View {
        if let date = model.lastScanDate {
            Text(Format.scanned(date, now: now))
                .font(Typography.note)
                .foregroundStyle(Palette.quietText)
                .accessibilityIdentifier("home.lastScan")
        }
    }

    private var scanButton: some View {
        Button {
            model.startScan()
        } label: {
            Group {
                if model.hasFinishedFullScan {
                    Text("Scan Again")
                } else {
                    Text("Scan Library")
                }
            }
            .font(.body)
            .foregroundStyle(Palette.accentText)
            .frame(minHeight: Hit.minimum)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("home.scan")
    }
}
