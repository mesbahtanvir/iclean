import CleanupKit
import SwiftUI

// The screens Home shows when there is no list: one sentence, and at most one button (spec 009
// section 6.2). They look like the system's ContentUnavailableView (a symbol, a title, a sentence,
// an action) but are drawn by `HomeMessage`: the system view fails Xcode's Dynamic Type audit on
// the first screen of the app, and this one scrolls instead of clipping at the largest text sizes.

/// A symbol, a title, a sentence and at most one button, centred in the screen and scrolling when
/// the text is too large to fit.
struct HomeMessage<Actions: View>: View {
    let systemImage: String
    let title: Text
    let message: Text
    @ViewBuilder var actions: Actions

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 48

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Space.m) {
                    Image(systemName: systemImage)
                        .font(.system(size: min(symbolSize, 96)))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Space.s)
                        .accessibilityHidden(true)
                    title
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    message
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    actions
                        .padding(.top, Space.m)
                }
                .readableColumn(Layout.access)
                .padding(.horizontal, Space.xl)
                .padding(.vertical, Space.xl)
                .frame(minHeight: proxy.size.height)
            }
        }
    }
}

extension HomeMessage where Actions == EmptyView {
    init(systemImage: String, title: Text, message: Text) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

/// Opening the saved data, or building results from scratch. Silent for a moment, then a spinner,
/// so a quick launch never flashes one. The area fills the screen, so nothing jumps when it ends.
struct HomeLaunching: View {
    let opening: Bool

    var body: some View {
        let caption =
            opening
            ? String(localized: "Getting ready…") : String(localized: "Getting your results ready…")
        DelayedProgress(caption: LocalizedStringKey(caption))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption)
            .accessibilityIdentifier("home.opening")
    }
}

/// The saved results could not be read. This is the whole screen: no scan button, no claim about
/// the library. Settings (the gear) is how to start over.
struct HomeFailed: View {
    var body: some View {
        HomeMessage(
            systemImage: "exclamationmark.triangle",
            title: Text("Saved results couldn’t be read"),
            message: Text("Your photos are safe. To start over, delete iclean’s data in Settings.")
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.storeUnreadable")
    }
}

/// Never scanned: the first screen after access is one sentence and one big button.
struct HomeFirstRun: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeMessage(
            systemImage: "photo.stack",
            title: Text("Find photos you can clean up"),
            message: Text(
                "iclean looks for duplicates, similar shots, blurry photos, screenshots and large videos. You review everything before anything is removed."
            )
        ) {
            Button("Scan Library") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .actionShape()
                .accessibilityIdentifier("home.scan")
        }
    }
}

/// A scan was interrupted (the app was closed or killed) before it found anything to show.
struct HomeInterruptedEmpty: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeMessage(
            systemImage: "arrow.clockwise.circle",
            title: Text("Your last scan stopped early"),
            message: Text("Resuming picks up where it stopped. Nothing is lost.")
        ) {
            Button("Resume Scan") { model.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .actionShape()
                .accessibilityIdentifier("home.resume")
        }
    }
}

/// A full scan finished and found nothing, or everything it found was removed, or the library is
/// empty. The container carries `results.empty`.
struct HomeNothingToShow: View {
    enum Kind { case clean, allCleaned, emptyLibrary }

    let kind: Kind
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeMessage(systemImage: symbol, title: title, message: message) {
            // An empty library can only be fixed outside iclean; scanning is still offered.
            Button("Scan Again") { model.startScan() }
                .buttonStyle(.bordered)
                .tint(Palette.accentText)
                .controlSize(.large)
                .actionShape()
                .accessibilityIdentifier("home.scan")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("results.empty")
    }

    private var symbol: String {
        kind == .emptyLibrary ? "photo.on.rectangle.angled" : "checkmark.circle"
    }

    private var title: Text {
        switch kind {
        case .clean: Text("Nothing to clean up")
        case .allCleaned: Text("All cleaned up")
        case .emptyLibrary: Text("No photos to check")
        }
    }

    private var message: Text {
        switch kind {
        case .clean:
            // Photos that only iCloud has were not looked at, so they are not "checked".
            let checked = max(0, (model.libraryItemCount ?? 0) - model.results.notScannedCount)
            if checked == 1 {
                return Text(
                    "We checked 1 item and found no duplicates, similar shots, blurry photos, screenshots or large videos."
                )
            } else if checked > 1 {
                return Text(
                    "We checked \(checked, format: .number) photos and videos and found no duplicates, similar shots, blurry photos, screenshots or large videos."
                )
            }
            return Text(
                "No duplicates, similar shots, blurry photos, screenshots or large videos found.")
        case .allCleaned:
            return Text(
                "You’ve removed what iclean found. Removed photos stay in Recently Deleted for at least 30 days."
            )
        case .emptyLibrary:
            #if os(macOS)
                return Text(
                    "iclean found no photos or videos to check. If your library is not empty, macOS may be sharing a different one: in Photos, choose Settings, General, then Use as System Photo Library, and scan again."
                )
            #else
                return Text(
                    "iclean can’t find any photos or videos to check. Add some, then scan again.")
            #endif
        }
    }
}

// MARK: Notices

/// What Home says about its own situation, as footnotes in the periphery: only some of your photos
/// are shared, the saved data has a problem, some photos are only in iCloud. Never red, never a
/// card; they always come last. The slot exists in every state.
struct HomeNotices: View {
    @Environment(AppModel.self) private var model

    /// Whether there is anything to show, so a list can skip an empty row.
    static func isEmpty(_ model: AppModel) -> Bool {
        model.access != .limited && model.storeProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if model.access == .limited {
                QuietNote(
                    "iclean can only see the photos you chose to share.",
                    systemImage: "info.circle"
                )
                .accessibilityIdentifier("home.limitedAccess")
            }
            // In the failed state the unreadable notice is the screen itself.
            if model.launchPhase != .failed {
                switch model.storeProblem {
                case .volatile:
                    QuietNote(
                        "**Your choices won’t be saved this time.** iclean couldn’t open the place it keeps its data, so what you pick is forgotten when you quit. You can delete iclean’s data in Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .accessibilityIdentifier("home.storeVolatile")
                case .unreadable:
                    QuietNote(
                        "**Saved results couldn’t be read.** Your photos are safe. To start over, delete iclean’s data in Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .accessibilityIdentifier("home.storeUnreadable")
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "1 item is only in iCloud, so it wasn’t checked. iclean never downloads photos." Once, in one
/// phrasing, everywhere.
struct ICloudFootnote: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Group {
                if count == 1 {
                    QuietNote(
                        "1 item is only in iCloud, so it wasn’t checked. iclean never downloads photos.",
                        systemImage: "icloud")
                } else {
                    QuietNote(
                        "\(count, format: .number) items are only in iCloud, so they weren’t checked. iclean never downloads photos.",
                        systemImage: "icloud")
                }
            }
            .accessibilityIdentifier("results.notScanned")
        }
    }
}
