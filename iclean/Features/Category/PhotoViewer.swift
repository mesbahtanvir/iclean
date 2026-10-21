import CleanupKit
import SwiftUI

/// Full-screen view of one item, with zoom.
struct PhotoViewer: View {
    let assetID: String

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Thumbnail(assetID: assetID, maxPixels: 2048, contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, min(5, $0.magnification)) }
                        .onEnded { _ in if scale < 1.05 { scale = 1 } }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .accessibilityLabel("Photo")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItemGroup(placement: Self.actionsPlacement) {
                        Button {
                            model.toggle(assetID)
                        } label: {
                            Label(
                                model.isSelected(assetID) ? "Don't Remove" : "Remove",
                                systemImage: model.isSelected(assetID) ? "arrow.uturn.backward" : "trash")
                        }
                        .accessibilityIdentifier("viewer.toggleSelect")
                        Spacer()
                        Button {
                            Task {
                                await model.alwaysKeep(assetID)
                                dismiss()
                            }
                        } label: {
                            Label("Always Keep", systemImage: "pin")
                        }
                        .accessibilityIdentifier("viewer.alwaysKeep")
                    }
                }
        }
        #if os(macOS)
            // A sheet on the Mac has no size of its own.
            .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        #endif
    }

    /// The bottom bar on iPhone; the Mac has none, so the actions go in the window toolbar.
    private static var actionsPlacement: ToolbarItemPlacement {
        #if os(macOS)
            .primaryAction
        #else
            .bottomBar
        #endif
    }
}
