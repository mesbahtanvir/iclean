import CleanupKit
import SwiftUI

/// Asks for Photos access, or says it is off. One column: a symbol, a title, a sentence, two quiet
/// reassurances, and one full-width button (spec 009 section 6.1). Limited access is not a state
/// here; it is a quiet note on Home.
struct AccessView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 56
    /// The system's permission dialog is up: the button waits, it does not ask twice.
    @State private var isRequesting = false

    private var isDenied: Bool { model.access == .denied }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: Space.xl) {
                    // The symbol is decoration, and the first thing to go when text is large.
                    if !typeSize.isAccessibilitySize {
                        Image(systemName: "photo.stack")
                            .font(.system(size: symbolSize))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
                    VStack(spacing: Space.m) {
                        title
                        message
                    }
                    if !isDenied { trustRows }
                    #if os(macOS)
                        // On the Mac the button sits under the text at a fixed width.
                        actionButton.frame(width: 280)
                    #endif
                }
                .readableColumn(Layout.access)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.xxl)
                .frame(minHeight: proxy.size.height)
            }
        }
        #if os(iOS)
            // Pinned, so it is never under the home indicator or off the screen at large text.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                actionButton
                .readableColumn(Layout.access)
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        #endif
    }

    // MARK: Content

    private var title: some View {
        Group {
            if isDenied {
                Text("Photos access is off")
            } else {
                Text("Clean up your photos")
            }
        }
        .font(.largeTitle.bold())
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
    }

    private var message: some View {
        Group {
            if isDenied {
                // The message itself, at body weight and not gray: it is what the person must do.
                #if os(macOS)
                    Text(
                        "iclean can’t see your photos, so nothing is scanned. Open System Settings, choose Privacy & Security, then Photos, and turn on iclean. macOS may ask you to reopen iclean."
                    )
                #else
                    Text(
                        "iclean can’t see your photos, so nothing is scanned. Turn on access in Settings to start."
                    )
                #endif
            } else {
                Text(
                    "iclean finds duplicate, blurry and similar photos, screenshots and big videos so you can free up space."
                )
            }
        }
        .font(.body)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Two reassurances that answer the worry before it is asked: where the photos go, and whether
    /// anything can be undone.
    private var trustRows: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            TrustRow(
                systemImage: "lock.shield",
                text: Text(
                    "Everything stays on this \(Device.noun). No account, no internet connection, nothing collected."
                ))
            TrustRow(
                systemImage: "arrow.uturn.backward.circle",
                text: Text(
                    "You review every photo first. Removed photos stay in Recently Deleted so you can get them back."
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Action

    @ViewBuilder private var actionButton: some View {
        if isDenied {
            Button {
                if let url = URL(string: Self.settingsURLString) { openURL(url) }
            } label: {
                Text("Open \(Device.systemSettings)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("access.openSettings")
        } else if isRequesting {
            // Waiting for the system dialog: the button is disabled and says so, it is not a
            // faded slab.
            Button {
            } label: {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(true)
            .accessibilityLabel("Allow Access to Photos")
            .accessibilityIdentifier("access.allow")
        } else {
            Button {
                isRequesting = true
                Task {
                    await model.requestAccess()
                    isRequesting = false
                }
            } label: {
                Text("Allow Access to Photos")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("access.allow")
        }
    }

    /// Where the person can allow Photos access: the app's page in Settings on iOS, the Photos list
    /// under Privacy & Security in System Settings on the Mac.
    private static var settingsURLString: String {
        #if os(macOS)
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos"
        #else
            UIApplication.openSettingsURLString
        #endif
    }
}

/// One quiet reassurance: a secondary glyph in a fixed column, so the words of every row start at
/// the same place, and the text below it.
private struct TrustRow: View {
    let systemImage: String
    let text: Text

    @ScaledMetric(relativeTo: .subheadline) private var glyphWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: systemImage)
                .frame(width: glyphWidth)
                .accessibilityHidden(true)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}
