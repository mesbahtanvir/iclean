#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// What starting a scan means right now, from the same state machine as the phone's Home
    /// (`HomeState`, spec 009 section 0.2). The toolbar, the Scan menu and the sidebar footer all ask
    /// it, so none of them can offer a scan the phone's Home would not: not while the saved data is
    /// opening or being built, not after it could not be read, and not while a scan is running or
    /// finishing.
    enum MacScanAction: Equatable {
        /// The first scan: "Scan Library".
        case scan
        /// A full scan has finished before: "Scan Again".
        case again
        /// A scan was cut off: "Resume Scan". The only way on, so "Scan Again" is not offered.
        case resume

        @MainActor
        static func current(_ model: AppModel) -> MacScanAction? {
            guard model.access == .full || model.access == .limited else { return nil }
            guard !model.isScanning, !model.isFinishing else { return nil }
            switch HomeState(model) {
            case .launching, .failed:
                return nil
            case .interruptedEmpty:
                return .resume
            case .results:
                if model.hasInterruptedScan { return .resume }
                return model.hasFinishedFullScan ? .again : .scan
            case .firstRun:
                return .scan
            case .emptyLibrary, .allCleaned, .clean:
                return .again
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .scan: "Scan Library"
            case .again: "Scan Again"
            case .resume: "Resume Scan"
            }
        }
    }

    /// The scan controls in the window's toolbar (spec 009 section 6.15): Scan Library (or Scan Again,
    /// or Resume Scan) when nothing is running, and Pause or Resume and Stop while a scan is. A
    /// toolbar is where a Mac looks for the one thing the window can do; the same actions are in the
    /// Scan menu with their shortcuts.
    ///
    /// These are views, not toolbar content, so the state they read re-draws them and not the shell.
    /// Their ids are `toolbar.scan` and `toolbar.resume`; `home.scan` and `home.resume` stay with the
    /// buttons in the window's content and in the sidebar, so one window never has two views with the
    /// same id (specs/001-photo-cleanup/contracts/ui.md).
    struct ScanToolbarButtons: View {
        @Environment(AppModel.self) private var model

        var body: some View {
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
            } else if let action = MacScanAction.current(model) {
                if action == .resume {
                    Button {
                        model.startScan()
                    } label: {
                        Label("Resume Scan", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Pick up the scan where it stopped (Command-R)")
                    .accessibilityIdentifier("toolbar.resume")
                } else {
                    Button {
                        model.startScan()
                    } label: {
                        if action == .again {
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
