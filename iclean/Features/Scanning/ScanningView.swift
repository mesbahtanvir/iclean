import CleanupKit
import SwiftUI

/// The scan, as a quiet status: a background job, not the screen's subject (spec 009 section 6.4).
/// One list row with the status, a thin bar, one count line, Pause and Stop, and one footnote.
///
/// This is the only view that reads `model.progress`, so a progress tick re-evaluates this row and
/// nothing else. It does not announce anything: the one VoiceOver announcement at the end of a scan
/// is posted by the model once the final results are built.
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
                    .foregroundStyle(.secondary)
            } else if let p {
                // One text, "12,408 of 30,112 checked": a test and VoiceOver read it whole.
                Text("\(p.processed, format: .number) of \(p.total, format: .number) checked")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let failed = p?.failed, failed > 0 {
                Text("\(failed, format: .number) couldn’t be checked")
                    .font(Typography.note)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("scan.failed")
            }
            if showsControls { controls(paused: paused) }
            if !paused, let note = whenYouLeave {
                Text(note)
                    .font(Typography.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scan.whenYouLeave")
            }
        }
        .padding(.vertical, Space.xs)
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

    @ViewBuilder private func primaryControl(paused: Bool) -> some View {
        if paused {
            let resume = Button("Resume") { model.resumeScan() }
                .controlSize(.large)
                .accessibilityIdentifier("scan.resume")
            // The one filled control on screen is the Review bar when there is one.
            if model.summary.count > 0 {
                resume.buttonStyle(.bordered)
            } else {
                resume.buttonStyle(.borderedProminent)
            }
        } else {
            Button("Pause") { model.pauseScan() }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("scan.pause")
        }
    }

    private var stopButton: some View {
        Button {
            model.stopScan()
        } label: {
            Text("Stop")
                .foregroundStyle(Color.secondary)
                .frame(minHeight: Hit.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("scan.stop")
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
