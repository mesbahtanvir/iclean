#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// The scan controls in the window's toolbar (spec 009 section 6.15): Scan Library (or Scan Again,
    /// or Resume Scan) when nothing is running, and Pause or Resume and Stop while a scan is. A
    /// toolbar is where a Mac looks for the one thing the window can do; the same actions are in the
    /// Scan menu with their shortcuts.
    ///
    /// These are views, not toolbar content, so the state they read re-draws them and not the shell.
    struct ScanToolbarButtons: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            let hasAccess = model.access == .full || model.access == .limited
            if model.isScanning {
                if model.progress?.state == .paused {
                    Button {
                        model.resumeScan()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .help("Resume the scan")
                    .accessibilityIdentifier("scan.resume")
                } else {
                    Button {
                        model.pauseScan()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .help("Pause the scan (Option-Command-P)")
                    .accessibilityIdentifier("scan.pause")
                }
                // Not destructive: stopping keeps everything found so far.
                Button {
                    model.stopScan()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the scan and keep what it found (Command-period)")
                .accessibilityIdentifier("scan.stop")
            } else if model.hasInterruptedScan {
                Button {
                    model.startScan()
                } label: {
                    Label("Resume Scan", systemImage: "arrow.clockwise")
                }
                .labelStyle(.titleAndIcon)
                .help("Pick up the scan where it stopped (Command-R)")
                .accessibilityIdentifier("toolbar.resume")
            } else if model.launchPhase == .ready, hasAccess, !model.isFinishing {
                Button {
                    model.startScan()
                } label: {
                    if model.hasFinishedFullScan {
                        Label("Scan Again", systemImage: "magnifyingglass")
                    } else {
                        Label("Scan Library", systemImage: "magnifyingglass")
                    }
                }
                .labelStyle(.titleAndIcon)
                .help("Scan the photo library (Command-R)")
                .accessibilityIdentifier("toolbar.scan")
            }
        }
    }

    /// "12,408 of 30,112 checked" in the middle of the toolbar while a scan runs. The one place the
    /// shell reads the scan's progress.
    struct ScanToolbarStatus: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            if let p = model.progress, model.isScanning, p.total > 0 {
                Text("\(p.processed, format: .number) of \(p.total, format: .number) checked")
                    .font(Typography.note)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
#endif
