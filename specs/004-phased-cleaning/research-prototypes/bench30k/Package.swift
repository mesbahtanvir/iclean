// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "bench30k",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../../../Packages/CleanupKit")
    ],
    targets: [
        .executableTarget(
            name: "bench30k",
            dependencies: [.product(name: "CleanupKit", package: "CleanupKit")],
            path: "Sources/bench30k",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
