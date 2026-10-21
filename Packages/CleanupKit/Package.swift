// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CleanupKit",
    platforms: [.iOS(.v18), .macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        // Developer tooling: a labelled test photo library and a check that runs the real
        // pipeline against it on any device. Used by DEBUG builds only.
        .library(name: "BaselineKit", targets: ["BaselineKit"]),
    ],
    targets: [
        .target(
            name: "CleanupKit",
            path: "Sources/CleanupKit",
            // The scan and the results build are pixel and pair loops. Unoptimized they run
            // about 80 times slower (a photo's sharpness: 184 ms against 2 ms), so a debug app
            // scanned 30,000 photos in hours and built results in minutes (spec 008). Optimizing
            // this one module keeps the app itself debuggable.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(
            name: "BaselineKit",
            dependencies: ["CleanupKit"],
            path: "Sources/BaselineKit"
        ),
        .testTarget(
            name: "CleanupKitTests",
            dependencies: ["CleanupKit", "BaselineKit"],
            path: "Tests/CleanupKitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
