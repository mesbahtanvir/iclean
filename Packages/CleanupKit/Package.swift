// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CleanupKit",
    platforms: [.iOS(.v18), .macOS(.v26)],
    products: [
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        // Developer tooling: a labelled test photo library and a check that runs the real
        // pipeline against it on any device. Used by DEBUG builds only.
        .library(name: "BaselineKit", targets: ["BaselineKit"]),
    ],
    targets: [
        .target(
            name: "CleanupKit",
            path: "Sources/CleanupKit"
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
