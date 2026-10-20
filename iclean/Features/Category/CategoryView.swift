import CleanupKit
import SwiftUI

/// Items or groups in one category, with selection toggles.
struct CategoryView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @State private var showConfirm = false
    @State private var viewing: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        let result = model.results.category(category)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(category.explanation)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    if let result {
                        if category == .largeVideos {
                            listLayout(result)
                        } else if result.groups.first?.type == .single {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(result.allMembers, id: \.self) { cell($0, group: nil) }
                            }
                        } else {
                            ForEach(result.groups) { group in groupSection(group) }
                        }
                    } else if model.launchPhase != .ready || model.isBuildingResults {
                        // Results are still being restored or built: never say "nothing" before they are.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                            .accessibilityIdentifier("category.loading")
                    } else {
                        ContentUnavailableView("Nothing here", systemImage: "checkmark.seal")
                    }
                }
                .padding(.vertical)
            }
            // A restored screen opens on the photo the person last touched.
            .onAppear { scrollToRestoredPhoto(proxy, in: result) }
            .onChange(of: result?.allMembers.count) { scrollToRestoredPhoto(proxy, in: result) }
        }
        .navigationTitle(category.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { selectAllButton(result) }
        }
        .safeAreaInset(edge: .bottom) { removeBar }
        .sheet(isPresented: $showConfirm) { ConfirmSheet(category: category) }
        .fullScreenCover(
            item: Binding(get: { viewing.map(Viewing.init) }, set: { viewing = $0?.id })
        ) {
            PhotoViewer(assetID: $0.id)
        }
    }

    private func scrollToRestoredPhoto(_ proxy: ScrollViewProxy, in result: CategoryResult?) {
        guard let id = model.restoredFocus, result?.allMembers.contains(id) == true else { return }
        proxy.scrollTo(id, anchor: .center)
    }

    // MARK: Layouts

    private func groupSection(_ group: ResultGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: Route.group(category, containing: group)) {
                HStack {
                    Group {
                        if group.type == .similarShots {
                            Text("\(group.members.count) similar shots")
                        } else {
                            Text("\(group.members.count) copies")
                        }
                    }
                    .font(.headline)
                    Image(systemName: "chevron.right").font(.footnote)
                    Spacer()
                }
            }
            .accessibilityIdentifier("category.group.\(group.id)")
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(group.members, id: \.self) { cell($0, group: group) }
            }
        }
        .padding(.horizontal, 4)
    }

    private func listLayout(_ result: CategoryResult) -> some View {
        LazyVStack(spacing: 8) {
            ForEach(result.allMembers, id: \.self) { id in
                let item = model.results.items[id]
                HStack(spacing: 12) {
                    Thumbnail(assetID: id)
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading) {
                        Text(
                            Format.bytes(
                                item?.effectiveByteSize ?? 0, estimate: item?.sizeIsEstimate ?? true
                            )
                        )
                        .font(.headline)
                        if let d = item?.metadata.duration {
                            Text(Format.duration(d)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    SelectionMark(selected: model.isSelected(id))
                }
                .padding(.horizontal)
                .contentShape(Rectangle())
                .onTapGesture { model.toggle(id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(model.isSelected(id) ? .isSelected : [])
                .accessibilityIdentifier("category.item.\(id)")
                .accessibilityAction(named: "View full screen") { viewing = id }
            }
        }
    }

    private func cell(_ id: String, group: ResultGroup?) -> some View {
        ItemCell(
            assetID: id, isKeeper: group?.keepers.contains(id) ?? false,
            confidence: group?.confidence ?? .normal, onView: { viewing = id })
    }

    // MARK: Bars

    private func selectAllButton(_ result: CategoryResult?) -> some View {
        let ids = result?.removable ?? []
        let all = !ids.isEmpty && ids.allSatisfy(model.isSelected)
        return Button(all ? "Deselect All" : "Select All") {
            model.setSelected(ids, !all)
        }
        .accessibilityIdentifier("category.selectAll")
    }

    private var removeBar: some View {
        let count = model.selectedCount(in: category)
        return Button {
            showConfirm = true
        } label: {
            Text("Remove \(count) Selected")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(count == 0)
        .padding()
        .background(.bar)
        .accessibilityIdentifier("category.removeSelected")
    }
}

private struct Viewing: Identifiable {
    let id: String
}

/// One photo with its badges. Tap toggles selection.
struct ItemCell: View {
    let assetID: String
    var isKeeper: Bool
    var confidence: Confidence = .normal
    var onView: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let item = model.results.items[assetID]
        let selected = model.isSelected(assetID)
        Thumbnail(assetID: assetID)
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                SelectionMark(selected: selected).padding(6)
            }
            .overlay(alignment: .topLeading) {
                Button(action: onView) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(4)
                .accessibilityHidden(true)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if isKeeper { Badge(text: "Keep", systemImage: "checkmark.seal.fill") }
                    if item?.metadata.isFavorite == true {
                        Badge(text: nil, systemImage: "heart.fill")
                    }
                    if let albums = item?.metadata.albumNames, !albums.isEmpty {
                        Badge(text: nil, systemImage: "rectangle.stack")
                            .accessibilityIdentifier("category.albumBadge")
                    }
                    if item?.analysisSource == .cloudPreview || confidence == .lower {
                        Badge(text: nil, systemImage: "icloud")
                            .accessibilityIdentifier("category.previewOnlyBadge")
                    }
                }
                .padding(4)
            }
            .opacity(selected ? 0.75 : 1)
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(assetID) }
            .onLongPressGesture(minimumDuration: 0.4) { onView() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(item: item))
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("category.item.\(assetID)")
            .accessibilityAction(named: "View full screen", onView)
            .accessibilityAction(named: "Always keep") {
                Task { await model.alwaysKeep(assetID) }
            }
    }

    private func label(item: CleanupKit.LibraryItem?) -> String {
        var parts: [String] = []
        if let date = item?.metadata.captureDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if isKeeper { parts.append(String(localized: "Suggested to keep")) }
        if item?.metadata.isFavorite == true { parts.append(String(localized: "Favorite")) }
        if let albums = item?.metadata.albumNames, !albums.isEmpty {
            parts.append(String(localized: "In albums: \(albums.joined(separator: ", "))"))
        }
        if item?.analysisSource == .cloudPreview || confidence == .lower {
            parts.append(String(localized: "Checked from a preview only"))
        }
        parts.append(
            model.isSelected(assetID)
                ? String(localized: "Selected for removal") : String(localized: "Not selected"))
        return parts.joined(separator: ", ")
    }
}

struct SelectionMark: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, selected ? Color.red : Color.black.opacity(0.3))
            .accessibilityHidden(true)
    }
}

struct Badge: View {
    let text: String?
    let systemImage: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
            // On a fixed-size thumbnail there is no room for large text: show the icon
            // only. The cell's VoiceOver label still says "Suggested to keep".
            if let text, !typeSize.isAccessibilitySize { Text(text) }
        }
        .font(.caption2.bold())
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityIdentifier(text == "Keep" ? "category.keeperBadge" : "")
    }
}
