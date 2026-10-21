import CleanupKit
import SwiftUI

/// The last full scans and how each ended (003 FR-012, spec 009 section 6.13). Reached from
/// Settings, so that screen stays short. Quick checks for new photos run on every return to the app,
/// so they are folded into one quiet line instead of burying the real scans.
struct RecentScansView: View {
    @Environment(AppModel.self) private var model
    @State private var history: ScanHistory?

    var body: some View {
        Group {
            if let history {
                if history.isEmpty {
                    ContentUnavailableView(
                        "No Scans Yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Scans you run will be listed here.")
                    )
                    .accessibilityIdentifier("recentScans.empty")
                } else {
                    list(history)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle("Recent Scans")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { history = ScanHistory(await model.recentSessions()) }
    }

    private func list(_ history: ScanHistory) -> some View {
        List {
            RecentScansSection(history: history, showsHeader: false)
        }
    }
}

/// The scans as one section, so the Mac Settings window can show them under the other data rows.
struct RecentScansSection: View {
    let history: ScanHistory
    /// The Mac window has no screen title to say what the rows are, so its section has a header.
    var showsHeader = true

    var body: some View {
        if showsHeader {
            Section {
                rows
            } header: {
                Text("Recent Scans")
            } footer: {
                footer
            }
        } else {
            Section {
                rows
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if history.isEmpty {
            Text("Scans you run will be listed here.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recentScans.empty")
        } else {
            ForEach(history.scans) { scan in
                ScanRow(session: scan)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if let line = history.quickChecksLine { Text(line) }
    }
}

/// The sessions split the way the screen shows them: up to ten full scans, newest first, and what
/// the quick checks add up to.
struct ScanHistory {
    static let limit = 10

    let scans: [ScanSession]
    let quickChecks: Int
    let lastQuickCheck: Date?

    var isEmpty: Bool { scans.isEmpty && quickChecks == 0 }

    init(_ sessions: [ScanSession]) {
        let ordered = sessions.sorted { $0.when > $1.when }
        scans = Array(ordered.filter { $0.kind == .full }.prefix(Self.limit))
        let quick = ordered.filter { $0.kind == .quickCheck }
        quickChecks = quick.count
        lastQuickCheck = quick.first?.when
    }

    /// "Checked for new photos 12 times · last today at 1:16 PM".
    var quickChecksLine: String? {
        guard quickChecks > 0, let last = lastQuickCheck else { return nil }
        let when = ScanDay.phrase(for: last, capitalized: false)
        return String(localized: "Checked for new photos \(quickChecks) times · last \(when)")
    }
}

extension ScanSession {
    /// When it ended, or when it began if it never did.
    fileprivate var when: Date { finishedAt ?? startedAt }
}

private struct ScanRow: View {
    let session: ScanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ScanDay.phrase(for: session.when, capitalized: true))
            Text(detail)
                .font(Typography.note)
                .foregroundStyle(.secondary)
            if session.failedItems > 0 {
                Text("\(session.failedItems) couldn’t be checked")
                    .font(Typography.note)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityIdentifier("settings.session")
    }

    private var outcome: String {
        switch session.state {
        case .completed: String(localized: "Completed")
        case .stopped: String(localized: "Stopped")
        case .paused, .running: String(localized: "Not finished")
        case .idle: String(localized: "Not started")
        }
    }

    /// "Full scan · Completed · 23 items", or "Full scan · Stopped · 4,200 of 30,214 items".
    private var detail: String {
        let kind = String(localized: "Full scan")
        return "\(kind) · \(outcome) · \(items)"
    }

    private var items: String {
        if session.state == .completed {
            return String(localized: "\(session.processedItems) items")
        }
        return String(localized: "\(session.processedItems) of \(session.totalItems) items")
    }

    /// Starts with how it ended, so the one word that matters is heard first.
    private var spoken: String {
        let when = ScanDay.phrase(for: session.when, capitalized: false)
        var parts = "\(outcome). " + String(localized: "Full scan, \(when), \(checked).")
        if session.failedItems > 0 {
            parts += " " + String(localized: "\(session.failedItems) couldn’t be checked.")
        }
        return parts
    }

    private var checked: String {
        session.state == .completed
            ? String(localized: "\(session.processedItems) items checked")
            : String(localized: "\(session.processedItems) of \(session.totalItems) items checked")
    }
}

/// "Today at 1:16 PM", "Yesterday at 9:02 AM", "Oct 21 at 1:16 PM"; the year only when it is not
/// this one.
enum ScanDay {
    static func phrase(for date: Date, capitalized: Bool, now: Date = .now) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return capitalized
                ? String(localized: "Today at \(time)") : String(localized: "today at \(time)")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return capitalized
                ? String(localized: "Yesterday at \(time)")
                : String(localized: "yesterday at \(time)")
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        let day =
            sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return String(localized: "\(day) at \(time)")
    }
}
