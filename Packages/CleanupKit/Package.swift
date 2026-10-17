// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CleanupKit",
    platforms: [.iOS(.v18), .macOS(.v26)],
    products: [
        .library(name: "CleanupKit", targets: ["CleanupKit"])
    ],
    targets: [
        .target(
            name: "CleanupKit",
            path: "Sources/CleanupKit"
        ),
        .testTarget(
            name: "CleanupKitTests",
            dependencies: ["CleanupKit"],
            path: "Tests/CleanupKitTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
