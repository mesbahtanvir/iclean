import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// The one place the device's name and its settings app are spelled, so a sentence is written once
/// and reads right on iPhone, iPad and Mac.
@MainActor
enum Device {
    /// "iPhone", "iPad" or "Mac".
    static var noun: String {
        #if os(macOS)
            String(
                localized: "Mac",
                comment:
                    "The device the app runs on, in a sentence such as 'Everything stays on this Mac.'"
            )
        #else
            UIDevice.current.userInterfaceIdiom == .pad
                ? String(
                    localized: "iPad",
                    comment:
                        "The device the app runs on, in a sentence such as 'Everything stays on this iPad.'"
                )
                : String(
                    localized: "iPhone",
                    comment:
                        "The device the app runs on, in a sentence such as 'Everything stays on this iPhone.'"
                )
        #endif
    }

    /// The name of the system's settings app.
    static var systemSettings: String {
        #if os(macOS)
            String(localized: "System Settings")
        #else
            String(localized: "Settings")
        #endif
    }
}
