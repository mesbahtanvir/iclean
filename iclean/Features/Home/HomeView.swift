import CleanupKit
import SwiftUI

/// Start a scan and see results.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                if model.access == .limited {
                    Section {
                        Label(
                            "Scanning only the photos you shared with iclean.",
                            systemImage: "info.circle")
                            .accessibilityIdentifier("home.limitedAccess")
                    }
                }
                Section {
                    if model.isScanning {
                        ScanningView()
                    } else {
                        scanButtons
                    }
                }
                ResultsView()
            }
            .navigationTitle("iclean")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("home.settings")
                }
            }
            .navigationDestination(for: CleanupCategory.self) { category in
                CategoryView(category: category)
            }
            .overlay(alignment: .bottom) { tripwireCount }
        }
    }

    @ViewBuilder private var scanButtons: some View {
        if model.hasInterruptedScan {
            Button {
                model.startScan()
            } label: {
                Label("Resume Scan", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("home.resume")
        }
        Button {
            model.startScan()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .accessibilityHidden(true)
                Text(model.lastScanDate == nil ? "Scan Library" : "Scan Again")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.headline)
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("home.scan")
        if let date = model.lastScanDate {
            Text("Last scan \(date, format: .relative(presentation: .named))")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("home.lastScan")
        }
    }

    @ViewBuilder private var tripwireCount: some View {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-NetworkTripwire") {
                Text("\(NetworkTripwire.attempts.count)")
                    .font(.caption2)
                    .opacity(0.01)
                    .accessibilityIdentifier("tripwire.count")
            }
        #endif
    }
}
