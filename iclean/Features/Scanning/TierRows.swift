import CleanupKit
import SwiftUI

// How a scan in tiers is told to the person (spec 017). The words say what they get, not how it works:
// quick wins are ready at once, the photo check finds duplicates and blurry photos, and the deep check
// compares photos for similar shots. Real counts only; there is no time estimate until one is measured.

extension ScanTier {
    /// "Quick wins", "Photo check", "Deep check".
    var title: String {
        switch self {
        case .instant: String(localized: "Quick wins")
        case .photos: String(localized: "Photo check")
        case .deep: String(localized: "Deep check")
        }
    }

    /// What the tier finds, in the words of the category rows.
    var finds: String {
        switch self {
        case .instant: String(localized: "Screenshots, recordings, large videos, bursts")
        case .photos: String(localized: "Duplicates and blurry photos")
        case .deep: String(localized: "Similar shots and photos that probably don’t matter")
        }
    }

    /// The header over the finds of a tier while a scan runs.
    var heading: String {
        switch self {
        case .instant: String(localized: "Ready now")
        case .photos: String(localized: "From the photo check")
        case .deep: String(localized: "From the deep check")
        }
    }

    /// What a tier's group says while it has found nothing and has not finished.
    var comingLater: String {
        switch self {
        case .instant: ""
        case .photos: String(localized: "Duplicates and blurry photos appear here as they’re found.")
        case .deep:
            String(localized: "Similar shots and unimportant photos appear here after the photo check.")
        }
    }

    /// Part of accessibility identifiers: `scan.tier.deep`, `results.section.deep`.
    var identifier: String {
        switch self {
        case .instant: "instant"
        case .photos: "photos"
        case .deep: "deep"
        }
    }
}

extension TierState {
    /// The short words at the end of a tier's row.
    var words: String {
        switch self {
        case .waiting: String(localized: "Waiting")
        case .running(let done, let total):
            String(localized: "\(done.formatted()) of \(total.formatted())")
        case .ready: String(localized: "Ready")
        case .waitingFor(let reason): reason.words
        case .notRun: String(localized: "Not run")
        }
    }

    /// What VoiceOver says for the row: the tier, then where it is, with the unit.
    func spoken(for tier: ScanTier) -> String {
        switch self {
        case .running(let done, let total):
            String(localized: "\(tier.title), \(done.formatted()) of \(total.formatted()) checked")
        default:
            "\(tier.title), \(words)"
        }
    }

    /// Ready or running: drawn in the accent, the way a link is, so the eye finds what is happening.
    var isActive: Bool {
        switch self {
        case .ready, .running: true
        default: false
        }
    }
}

extension DeepWait {
    /// At the end of a tier's row.
    var words: String {
        switch self {
        case .lowPowerMode: String(localized: "Waiting for Low Power Mode")
        }
    }

    /// The sentence that says why the deep check did not start by itself.
    var because: String {
        switch self {
        case .lowPowerMode:
            String(localized: "Low Power Mode is on, so iclean didn’t start comparing photos.")
        }
    }
}

enum DeepOfferText {
    /// "12,400 photos not compared yet. Similar shots and unimportant photos may be missing." In Low
    /// Power Mode it starts with why nothing started (spec 017 FR-015: never a claim that the library
    /// is clean while this work is owed).
    static func explanation(owed: Int, wait: DeepWait?) -> String {
        let photos = String(agreeing: AttributedString(localized: "^[\(owed) photo](inflect: true)"))
        let text = String(
            localized: "\(photos) not compared yet. Similar shots and unimportant photos may be missing."
        )
        guard let wait else { return text }
        return "\(wait.because) \(text)"
    }
}

/// The three tiers of a running scan, one row each: where it is, in the app's quiet words. The
/// glyph is a check when ready, a spinner while running, and an outline while it waits; VoiceOver
/// reads each row as one sentence.
struct TierRows: View {
    let status: ScanTierStatus

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(ScanTier.allCases, id: \.self) { tier in
                TierRow(tier: tier, state: status[tier])
            }
        }
    }
}

struct TierRow: View {
    let tier: ScanTier
    let state: TierState

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Side by side normally; stacked at accessibility sizes, so nothing is cut off.
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.m))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                TierGlyph(state: state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tier.title).font(.subheadline.weight(.semibold))
                    Text(tier.finds)
                        .font(Typography.note)
                        .foregroundStyle(Palette.quietText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.m) }
            Text(state.words)
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(state.isActive ? Palette.accentText : Palette.quietText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spoken(for: tier))
        .accessibilityIdentifier("scan.tier.\(tier.identifier)")
    }
}

/// A check, a spinner, a pause, a dashed circle or an outline: the state in a shape as well as in words.
struct TierGlyph: View {
    let state: TierState

    var body: some View {
        Group {
            switch state {
            case .ready:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
            case .running:
                ProgressView().controlSize(.small)
            case .waitingFor:
                Image(systemName: "pause.circle").foregroundStyle(Palette.quietText)
            case .notRun:
                Image(systemName: "circle.dashed").foregroundStyle(Palette.quietText)
            case .waiting:
                Image(systemName: "circle").foregroundStyle(Palette.quietText)
            }
        }
        .font(.title3)
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }
}

/// "Look Deeper" (or "Run Now" when the deep check waited for a reason) over what was not looked at: the
/// way to do the work a tiered scan left owed. A row in Home's list, like "Resume Scan".
struct DeepOfferRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.startDeepScan()
        } label: {
            VStack(alignment: .leading, spacing: Space.xs) {
                Group {
                    if model.deepWait == nil {
                        Text("Look Deeper")
                    } else {
                        Text("Run Now")
                    }
                }
                .font(.headline)
                .foregroundStyle(Palette.accentText)
                Text(DeepOfferText.explanation(owed: model.deepRemaining, wait: model.deepWait))
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: Hit.minimum, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("home.deepScan")
    }
}
