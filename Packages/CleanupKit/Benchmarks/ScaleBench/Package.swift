// swift-tools-version: 6.2
import PackageDescription

// Release benchmark for large libraries (spec 008). Uses only CleanupKit's public API, so what it
// measures is what the app runs: `swift run -c release --package-path Packages/CleanupKit/Benchmarks/ScaleBench`.
let package = Package(
    name: "ScaleBench",
    platforms: [.macOS(.v26)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ScaleBench",
            dependencies: [.product(name: "CleanupKit", package: "CleanupKit")],
            path: "Sources/ScaleBench")
    ],
    swiftLanguageModes: [.v6]
)
