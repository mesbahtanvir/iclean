#if DEBUG
    import BaselineKit
    import CleanupKit
    import SwiftUI

    /// DEBUG only: `-BaselineRun` runs the baseline library check by itself at launch and
    /// shows the outcome; `-BaselineExit` also ends the process with 0 (pass) or 1 (fail);
    /// `-BaselineRemove` removes the baseline assets instead. See docs/BASELINE_LIBRARY.md.
    enum BaselineMode {
        static var arguments: [String] { ProcessInfo.processInfo.arguments }
        static var isRequested: Bool { arguments.contains("-BaselineRun") }
        static var exitsWhenDone: Bool { arguments.contains("-BaselineExit") }
        static var removesInstead: Bool { arguments.contains("-BaselineRemove") }
    }

    @MainActor @Observable
    final class BaselineViewModel {
        enum Phase: Equatable {
            case idle
            case working(String)
            case done
            case failed(String)
        }

        var phase: Phase = .idle
        var report: BaselineReport?
        var log: [String] = []
        var scanProgress: Double?

        private let catalog = BaselineCatalogV4.make()

        // MARK: Actions

        /// Renders, imports what is missing, scans the baseline assets through the real
        /// pipeline and validates the result.
        func runAll() async {
            do {
                let (rendered, summary) = try await prepare()
                phase = .working("Scanning \(catalog.assets.count) assets")
                emit("scanning")
                let mapping = BaselinePhotoKit.mapping(catalog)
                let report = try await BaselineRunner.run(
                    catalog: catalog, rendered: rendered, library: PhotoKitLibrary(),
                    mapping: mapping, importSeconds: summary.seconds,
                    progress: { p in Task { @MainActor in self.scanProgress = p.fraction } })
                self.report = report
                try save(report)
                for line in report.summary().split(separator: "\n") { emit(String(line)) }
                phase = .done
                finish(passed: report.passed)
            } catch {
                phase = .failed("\(error)")
                emit("FAILED: \(error)")
                finish(passed: false)
            }
        }

        func importOnly() async {
            do {
                _ = try await prepare()
                phase = .done
                emit("import finished")
            } catch {
                phase = .failed("\(error)")
                emit("FAILED: \(error)")
            }
        }

        /// The system asks for confirmation before the assets go to Recently Deleted.
        func removeAll() async {
            phase = .working("Removing the baseline assets")
            do {
                try await BaselinePhotoKit.requestAccess()
                let n = try await BaselinePhotoKit.removeAll(catalog)
                phase = .done
                emit("removed \(n) baseline assets (they are in Recently Deleted)")
            } catch {
                phase = .failed("\(error)")
                emit("remove did not complete: \(error)")
            }
            if BaselineMode.exitsWhenDone { exit(0) }
        }

        // MARK: Steps

        private func prepare() async throws -> (
            [String: RenderedFile], BaselinePhotoKit.ImportSummary
        ) {
            phase = .working("Drawing the baseline photos and videos")
            emit("rendering \(catalog.assets.count) assets")
            let folder = FileManager.default.temporaryDirectory.appending(path: "iclean-baseline")
            try? FileManager.default.removeItem(at: folder)
            let rendered = try await BaselineRenderer.renderAll(catalog, to: folder)
            defer { try? FileManager.default.removeItem(at: folder) }

            phase = .working("Asking for Photos access")
            try await BaselinePhotoKit.requestAccess()

            phase = .working("Adding the baseline assets to Photos")
            emit("importing")
            let summary = try await BaselinePhotoKit.importMissing(
                catalog: catalog, rendered: rendered)
            emit(
                "imported \(summary.imported), already there \(summary.alreadyThere), \(String(format: "%.1f", summary.seconds)) s"
            )
            return (rendered, summary)
        }

        private func save(_ report: BaselineReport) throws {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try report.json().write(to: docs.appending(path: "baseline-report.json"))
        }

        private func finish(passed: Bool) {
            if BaselineMode.exitsWhenDone { exit(passed ? 0 : 1) }
        }

        private func emit(_ line: String) {
            log.append(line)
            print("[baseline] \(line)")
            fflush(stdout)
        }
    }

    struct BaselineView: View {
        var autoRun: Bool
        /// False when pushed inside another navigation stack (Settings), which must not be nested.
        var standalone = true
        @State private var model = BaselineViewModel()

        var body: some View {
            Group {
                if standalone { NavigationStack { list } } else { list }
            }
            .task {
                guard autoRun else { return }
                if BaselineMode.removesInstead {
                    await model.removeAll()
                } else {
                    await model.runAll()
                }
            }
        }

        private var list: some View {
            List {
                Section {
                    switch model.phase {
                    case .idle:
                        Text("Ready").accessibilityIdentifier("baseline.status")
                    case .working(let what):
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(what).accessibilityIdentifier("baseline.status")
                        }
                    case .done:
                        Text("Finished").accessibilityIdentifier("baseline.status")
                    case .failed(let why):
                        Text(why).foregroundStyle(.red).accessibilityIdentifier("baseline.status")
                    }
                    if let report = model.report {
                        Text(report.passed ? "PASS" : "FAIL")
                            .font(.title.bold())
                            .foregroundStyle(report.passed ? .green : .red)
                            .accessibilityIdentifier("baseline.result")
                    }
                }
                Section {
                    Button("Run Baseline Check") { Task { await model.runAll() } }
                        .accessibilityIdentifier("baseline.run")
                    Button("Add Baseline Photos Only") { Task { await model.importOnly() } }
                        .accessibilityIdentifier("baseline.import")
                    Button("Remove Baseline Photos", role: .destructive) {
                        Task { await model.removeAll() }
                    }
                    .accessibilityIdentifier("baseline.remove")
                } footer: {
                    Text(
                        "Adds about 73 small test photos and videos to the Photos library in an album called \"iclean Baseline\", scans only those, and compares the result with what is expected. With iCloud Photos on they sync like any photo; remove them afterwards."
                    )
                }
                if let report = model.report {
                    Section("Checks") {
                        ForEach(report.checks, id: \.id) { check in
                            VStack(alignment: .leading, spacing: 2) {
                                Label(check.title, systemImage: icon(check.status))
                                    .foregroundStyle(color(check.status))
                                if !check.detail.isEmpty {
                                    Text(check.detail).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("Device") {
                        Text("\(report.device.platform) \(report.device.model)")
                        Text(report.device.osVersion)
                        Text("Scan \(String(format: "%.1f", report.timings["scanSeconds"] ?? 0)) s")
                    }
                }
                if !model.log.isEmpty {
                    Section("Log") {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Baseline Library")
            .navigationBarTitleDisplayMode(.inline)
        }

        private func icon(_ s: BaselineStatus) -> String {
            switch s {
            case .pass: "checkmark.circle.fill"
            case .fail: "xmark.octagon.fill"
            case .skipped: "minus.circle"
            }
        }

        private func color(_ s: BaselineStatus) -> Color {
            switch s {
            case .pass: .green
            case .fail: .red
            case .skipped: .secondary
            }
        }
    }
#endif
