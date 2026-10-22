import CleanupKit
import SwiftUI

/// The screen a route leads to. One view for every shell that shows routes (Home's stack on a
/// phone, the Mac's detail pane), so a saved review is put back the same way everywhere.
struct RouteDestinationView: View {
    let route: Route

    @Environment(AppModel.self) private var model

    var body: some View {
        switch route {
        case .category(let category):
            CategoryView(category: category)
        case .group(let category, _):
            // A group that is gone shows its own "already taken care of" state.
            GroupDetailView(
                groupID: RouteValidator.group(for: route, in: model.results)?.id ?? "",
                category: category)
        }
    }
}
