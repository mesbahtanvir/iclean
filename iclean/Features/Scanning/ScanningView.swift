import CleanupKit
import SwiftUI

/// Scan progress with pause, resume and stop (001), plus what happens when you leave
/// the app and why a scan is paused (002 contracts/ui.md).
struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText(p))
                .font(.headline)
                .accessibilityIdentifier("scan.status")
            ProgressView(value: p?.fraction ?? 0)
                .accessibilityIdentifier("scan.progress")
                .accessibilityValue(Text("\(p?.processed ?? 0) of \(p?.total ?? 0)"))
            Text("\(p?.processed ?? 0) of \(p?.total ?? 0) checked")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let notScanned = p?.notScanned, notScanned > 0 {
                Text("\(notScanned) not scanned (only in iCloud)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let failed = p?.failed, failed > 0 {
                Text("\(failed) couldn't be checked")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("scan.failed")
            }
            HStack {
                if p?.state == .paused {
                    Button("Resume", systemImage: "play.fill") { model.resumeScan() }
                        .accessibilityIdentifier("scan.resume")
                } else {
                    Button("Pause", systemImage: "pause.fill") { model.pauseScan() }
                        .accessibilityIdentifier("scan.pause")
                }
                Spacer()
                Button("Stop", systemImage: "stop.fill", role: .destructive) { model.stopScan() }
                    .accessibilityIdentifier("scan.stop")
            }
            .buttonStyle(.bordered)
            if p?.state != .paused, let note = whenYouLeave {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("scan.whenYouLeave")
            }
        }
        .padding(.vertical, 4)
    }

    private var whenYouLeave: String? {
        switch model.continuation.allowance {
        case .unknown:
            nil
        case .continues:
            String(
                localized:
                    "Keeps scanning while you use other apps. Progress shows in the Dynamic Island and on the Lock Screen."
            )
        case .pausesOnLeave:
            String(localized: "Pauses when you leave iclean and continues when you come back.")
        case .runsWhileOpen:
            String(
                localized:
                    "Keeps scanning while iclean is open, even if its window is hidden. Pauses if your Mac goes to sleep and continues when it wakes."
            )
        }
    }

    private func statusText(_ p: ScanProgress?) -> String {
        guard let p else { return String(localized: "Starting…") }
        if p.isThermalPaused {
            #if os(macOS)
                return String(localized: "Paused to let your Mac cool down")
            #else
                return String(localized: "Paused to let your iPhone cool down")
            #endif
        }
        if p.state == .paused {
            switch p.pauseReason {
            case .stoppedOutsideApp: return String(localized: "Stopped from outside iclean")
            case .backgroundLimit: return String(localized: "Paused while you were away")
            case .storageUnavailable:
                return String(localized: "Couldn't save progress. Free up space, then tap Resume.")
            case .user, nil: return String(localized: "Paused")
            }
        }
        return String(localized: "Scanning your library…")
    }
}
