import CleanupKit
import SwiftUI

/// The last few scans and how they ended (003 FR-012). Reached from Settings, so that
/// screen stays short.
struct RecentScansView: View {
    @Environment(AppModel.self) private var model
    @State private var sessions: [ScanSession] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded, sessions.isEmpty {
                Section {
                    Text("No scans yet.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recentScans.empty")
                }
            }
            if !sessions.isEmpty {
                Section {
                    ForEach(sessions) { s in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(for: s))
                            Text(detail(for: s))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("settings.session")
                    }
                } footer: {
                    Text(footer)
                }
            }
        }
        .navigationTitle("Recent Scans")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            sessions = await model.recentSessions()
            loaded = true
        }
    }

    private func title(for s: ScanSession) -> String {
        let outcome: String =
            switch s.state {
            case .completed: String(localized: "Completed")
            case .stopped: String(localized: "Stopped")
            case .paused, .running: String(localized: "Unfinished")
            case .idle: String(localized: "Not started")
            }
        let kind =
            s.kind == .quickCheck ? String(localized: "Quick check") : String(localized: "Scan")
        return "\(kind) · \(outcome)"
    }

    private func detail(for s: ScanSession) -> String {
        let when = (s.finishedAt ?? s.startedAt).formatted(date: .abbreviated, time: .shortened)
        return "\(when) · " + String(localized: "\(s.processedItems) of \(s.totalItems)")
    }

    private var footer: String {
        let failed = sessions.reduce(0) { $0 + $1.failedItems }
        let interrupted = sessions.reduce(0) { $0 + $1.interruptedCount }
        var parts: [String] = []
        if failed > 0 { parts.append(String(localized: "\(failed) items couldn't be checked.")) }
        if interrupted > 0 {
            parts.append(String(localized: "\(interrupted) scans were interrupted and resumed."))
        }
        if parts.isEmpty { parts.append(String(localized: "Scans resume where they left off.")) }
        return parts.joined(separator: " ")
    }
}
