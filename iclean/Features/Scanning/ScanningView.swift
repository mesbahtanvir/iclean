import CleanupKit
import SwiftUI

/// Scan progress with pause, resume and stop.
struct ScanningView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.progress
        VStack(alignment: .leading, spacing: 12) {
            Text(statusText(p))
                .font(.headline)
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
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ p: ScanProgress?) -> String {
        guard let p else { return String(localized: "Starting…") }
        if p.isThermalPaused { return String(localized: "Paused to let your iPhone cool down") }
        if p.state == .paused { return String(localized: "Paused") }
        return String(localized: "Scanning your library…")
    }
}
