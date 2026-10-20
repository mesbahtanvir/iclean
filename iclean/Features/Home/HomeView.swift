import CleanupKit
import SwiftUI

/// Start a scan and see results.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// The screens pushed on Home. Typed, so they can be saved and put back after a restart.
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.access == .limited {
                    Section {
                        Label(
                            "Scanning only the photos you shared with iclean.",
                            systemImage: "info.circle"
                        )
                        .accessibilityIdentifier("home.limitedAccess")
                    }
                }
                storeBanner
                if model.launchPhase == .opening || model.launchPhase == .building {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(
                                model.launchPhase == .opening
                                    ? "Opening your saved results…" : "Getting your results ready…")
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("home.opening")
                    }
                } else {
                    Section {
                        if model.isScanning {
                            ScanningView()
                        } else {
                            scanButtons
                        }
                    }
                    if !model.continueRoute.isEmpty { continueRow }
                    if model.launchPhase == .ready { ResultsView() }
                }
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
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .category(let category):
                    CategoryView(category: category)
                case .group(let category, _):
                    if let group = RouteValidator.group(for: route, in: model.results) {
                        GroupDetailView(groupID: group.id, category: category)
                    } else {
                        GroupDetailView(groupID: "", category: category)
                    }
                }
            }
            .overlay(alignment: .bottom) { tripwireCount }
        }
        .alert(
            "iclean",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: path) { _, new in model.pathChanged(new) }
        // The saved review stack is put back once, when the launch has results to check it against.
        .onChange(of: model.restoredRoute) { _, new in restore(new) }
        .task { restore(model.restoredRoute) }
    }

    private func restore(_ restored: RestoredRoute?) {
        guard let restored, path.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { path = restored.path }
        model.restoredRoute = nil
    }

    @ViewBuilder private var storeBanner: some View {
        switch model.storeProblem {
        case .volatile:
            Section {
                Label("Progress won't be saved this time.", systemImage: "exclamationmark.triangle")
                    .accessibilityIdentifier("home.storeVolatile")
            } footer: {
                Text(
                    "iclean could not open its saved data. Settings can delete it and start fresh.")
            }
        case .unreadable:
            Section {
                Label(
                    "iclean couldn't read its saved data.", systemImage: "exclamationmark.triangle"
                )
                .accessibilityIdentifier("home.storeUnreadable")
            } footer: {
                Text(
                    "Your photos are untouched. Settings can delete the saved data and start fresh."
                )
            }
        case nil:
            EmptyView()
        }
    }

    /// Offered when the review is too old to open by itself, or a restore failed before.
    private var continueRow: some View {
        let category: CleanupCategory? = model.continueRoute.compactMap {
            if case .category(let c) = $0 { c } else { nil }
        }.first
        return Section {
            Button {
                model.continueReviewing()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Continue reviewing").font(.headline)
                    if let category {
                        Text(
                            "\(category.title), \(model.selectedCount(in: category)) selected"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("home.continue")
            Button("Not now") { model.dismissContinue() }
                .accessibilityIdentifier("home.continueDismiss")
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
