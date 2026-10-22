import CleanupKit
import SwiftUI

/// The scan, as a quiet status: a background job, not the screen's subject (spec 011 section 6.4).
/// One list row with the status, a thin bar, one count line, Pause and Stop, and one footnote.
///
/// This is the only view that reads `model.progress`, so a progress tick re-evaluates this row and
/// nothing else. It announces only changes of state (paused, resumed, stopped), never progress: the
/// announcement at the end of a scan is posted by the model once the final results are built.
struct ScanningView: View {
    /// False on the Mac, where Pause, Resume and Stop are in the toolbar and this is status only.
    var showsControls = true

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let p = model.progress
        let starting = p == nil || (p?.total ?? 0) == 0
        let paused = p?.state == .paused
        VStack(alignment: .leading, spacing: Space.m) {
            Text(statusText(p, starting: starting))
                .font(.headline)
                .accessibilityIdentifier("scan.status")
            progressBar(p, starting: starting, paused: paused)
            if starting {
                Text("Results appear here as they’re found.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.quietText)
            } else if let p {
                // One text, "12,408 of 30,112 checked": a test and VoiceOver read it whole.
                Text("\(p.processed, format: .number) of \(p.total, format: .number) checked")
                    .font(.subheadline)
                    .foregroundStyle(Palette.quietText)
            }
            if let failed = p?.failed, failed > 0 {
                Text("\(failed, format: .number) couldn’t be checked")
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
                    .accessibilityIdentifier("scan.failed")
            }
            if showsControls { controls(paused: paused) }
            if !paused, let note = whenYouLeave {
                Text(note)
                    .font(Typography.note)
                    .foregroundStyle(Palette.quietText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scan.whenYouLeave")
            }
        }
        .padding(.vertical, Space.xs)
        // Said when the state changes, whoever changed it: the button, the heat, or the system.
        .onChange(of: Phase(p)) { old, new in announce(from: old, to: new, p) }
    }

    // MARK: Pieces

    @ViewBuilder private func progressBar(_ p: ScanProgress?, starting: Bool, paused: Bool)
        -> some View
    {
        Group {
            if starting {
                ProgressView()
                    #if os(macOS)
                        // A bar, like the running one, not a spinner.
                        .progressViewStyle(.linear)
                    #endif
            } else {
                ProgressView(value: p?.fraction ?? 0)
            }
        }
        // Running is the accent; paused is secondary, so the periphery shows the state.
        .tint(paused ? Color.secondary : Color.accentColor)
        // A status, not a control: nothing to tap, so it is announced as text and has no hit area.
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Scan progress")
        .accessibilityValue(starting ? Text("") : Text("\(p?.processed ?? 0) of \(p?.total ?? 0)"))
        .accessibilityIdentifier("scan.progress")
    }

    /// Pause (or Resume) and Stop, side by side, or stacked at accessibility sizes.
    private func controls(paused: Bool) -> some View {
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s))
            : AnyLayout(HStackLayout(spacing: Space.m))
        return layout {
            primaryControl(paused: paused)
            if !typeSize.isAccessibilitySize { Spacer(minLength: Space.m) }
            stopButton
        }
    }

    /// Pause and Resume are one button whose words, id and look change, so VoiceOver keeps its focus
    /// on it and reads the new label; two different views would have dropped the focus.
    private func primaryControl(paused: Bool) -> some View {
        Button {
            if paused { model.resumeScan() } else { model.pauseScan() }
        } label: {
            if paused { Text("Resume") } else { Text("Pause") }
        }
        // The one filled control on screen is the Review bar when there is one.
        .buttonStyle(ScanControlStyle(prominent: paused && model.summary.count == 0))
        .accessibilityIdentifier(paused ? "scan.resume" : "scan.pause")
    }

    private var stopButton: some View {
        Button {
            model.stopScan()
            // The card is gone a moment later, so the one thing VoiceOver hears is this.
            AccessibilityNotification.Announcement(String(localized: "Scan stopped")).post()
        } label: {
            Text("Stop")
                .foregroundStyle(Palette.quietText)
                .frame(minWidth: Hit.minimum, minHeight: Hit.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("scan.stop")
    }

    // MARK: Announcements

    /// What the scan is doing, as far as the words on the card go.
    private enum Phase: Equatable {
        case starting, running, coolingDown, paused(ScanPauseReason?), ended

        init(_ p: ScanProgress?) {
            guard let p, p.total > 0 else {
                self = .starting
                return
            }
            if p.isThermalPaused {
                self = .coolingDown
            } else if p.state == .paused {
                self = .paused(p.pauseReason)
            } else if p.state == .stopped || p.state == .completed {
                self = .ended
            } else {
                self = .running
            }
        }
    }

    private func announce(from old: Phase, to new: Phase, _ p: ScanProgress?) {
        let text: String
        switch new {
        case .starting, .ended:
            // The model announces the end of a scan, and Stop says its own word.
            return
        case .running:
            // Only coming back from a pause is news; a scan that was just starting is not.
            guard old != .starting else { return }
            text = String(localized: "Scan resumed")
        case .coolingDown, .paused(.some(.stoppedOutsideApp)), .paused(.some(.backgroundLimit)),
            .paused(.some(.storageUnavailable)):
            // The reason is the news, and the card has the words for it.
            text = statusText(p, starting: false)
        case .paused(.user), .paused(nil):
            text = String(localized: "Scan paused")
        }
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Words

    private var whenYouLeave: String? {
        switch model.continuation.allowance {
        case .unknown:
            nil
        case .continues:
            String(
                localized: "Keeps scanning in the background. Progress shows on your Lock Screen.")
        case .pausesOnLeave:
            String(localized: "Keep iclean open to finish. It picks up where it left off.")
        case .runsWhileOpen:
            String(localized: "Keeps going if you close the window. Pauses while your Mac sleeps.")
        }
    }

    private func statusText(_ p: ScanProgress?, starting: Bool) -> String {
        guard let p, !starting else { return String(localized: "Starting…") }
        if p.isThermalPaused {
            return String(localized: "Paused to let your \(Device.noun) cool down")
        }
        if p.state == .paused {
            switch p.pauseReason {
            case .stoppedOutsideApp: return String(localized: "Stopped from outside iclean")
            case .backgroundLimit: return String(localized: "Paused while you were away")
            case .storageUnavailable:
                return String(
                    localized: "Couldn’t save progress. Free up space, then resume the scan.")
            case .user, nil: return String(localized: "Paused")
            }
        }
        return String(localized: "Scanning your library…")
    }
}

/// Pause, Resume and the look of both: the bordered gray capsule with the accent as text, or the
/// accent fill with a white label when Resume is the one next step. A style of its own because the
/// system's `.bordered` and `.borderedProminent` are different types, and swapping them would swap
/// the view and with it VoiceOver's focus.
private struct ScanControlStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, prominent: prominent)
    }

    private struct Look: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool

        @Environment(\.dynamicTypeSize) private var typeSize

        var body: some View {
            // A capsule turns into a blob around a label that wraps, so a rounded rectangle then.
            let shape =
                typeSize.isAccessibilitySize
                ? AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                : AnyShape(Capsule())
            configuration.label
                .font(.body)
                .foregroundStyle(
                    prominent ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.accentText)
                )
                .padding(.horizontal, Space.xl - Space.xs)
                .padding(.vertical, Space.m + 2)
                .background(
                    prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary),
                    in: shape
                )
                .contentShape(shape)
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}
