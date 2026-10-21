import CleanupKit
import SwiftUI

/// Compare the photos in a group side by side and change the keeper.
struct GroupDetailView: View {
    let groupID: String
    let category: CleanupCategory

    @Environment(AppModel.self) private var model

    var body: some View {
        let group = model.results.category(category)?.groups.first { $0.id == groupID }
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(group?.members ?? [], id: \.self) { id in
                        column(id, group: group!)
                    }
                }
                .padding()
                .scrollTargetLayout()
            }
            // A restored screen opens on the copy the person last touched.
            .onAppear {
                if let id = model.restoredFocus, group?.members.contains(id) == true {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .scrollTargetBehavior(.viewAligned)
        .accessibilityIdentifier("group.compare")
        .navigationTitle(category.title)
        .overlay {
            if group == nil {
                if model.launchPhase != .ready || model.isBuildingResults {
                    ProgressView().accessibilityIdentifier("group.loading")
                } else {
                    ContentUnavailableView("Group removed", systemImage: "checkmark")
                }
            }
        }
    }

    private func column(_ id: String, group: ResultGroup) -> some View {
        let item = model.results.items[id]
        let isKeeper = group.keepers.contains(id)
        let selected = model.isSelected(id)
        return VStack(alignment: .leading, spacing: 8) {
            Thumbnail(assetID: id, maxPixels: 800, contentMode: .fit)
                .frame(width: 260, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { model.toggle(id) }
            if let m = item?.metadata {
                Text("\(m.pixelWidth) × \(m.pixelHeight)")
                if let date = m.captureDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                }
                // Why this copy's date or details look less reliable than another copy's.
                ForEach(group.dateNotes[id] ?? [], id: \.self) { reason in
                    Label(reason.explanation, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("group.dateNote.\(id).\(reason.rawValue)")
                }
            }
            if let item {
                Text(Format.bytes(item.effectiveByteSize, estimate: item.sizeIsEstimate))
            }
            if isKeeper {
                Label("Suggested to keep", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                if !group.dateNotes.isEmpty, group.dateNotes[id] == nil {
                    Text("Its date shows no sign of being wrong.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("group.dateLikely.\(id)")
                }
            } else if group.type == .duplicatePhotos || group.type == .duplicateVideos {
                Button("Keep This One") { model.makeKeeper(id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("group.makeKeeper")
            }
            Toggle(isOn: Binding(get: { selected }, set: { _ in model.toggle(id) })) {
                Text("Remove")
            }
            .accessibilityIdentifier("group.toggle.\(id)")
        }
        .font(.subheadline)
        .frame(width: 260)
        .accessibilityElement(children: .contain)
    }
}
