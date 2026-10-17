import CleanupKit
import SwiftUI

/// Asks for Photos access and explains that nothing leaves the phone.
struct AccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Clean up your photos")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("iclean finds duplicate, blurry and similar photos, screenshots and big videos so you can free up space.")
                    .multilineTextAlignment(.center)
                Label {
                    Text("Everything stays on this iPhone. iclean never connects to the internet.")
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                if model.access == .denied {
                    Text("iclean can't see your photos. Allow access in Settings to start. Nothing is scanned until you do.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("access.openSettings")
                } else {
                    Button("Allow Access to Photos") {
                        Task { await model.requestAccess() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("access.allow")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}
