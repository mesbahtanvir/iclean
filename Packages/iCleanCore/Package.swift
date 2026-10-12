// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iCleanCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PhotoGateway", targets: ["PhotoGateway"]),
        .library(name: "ScanEngine", targets: ["ScanEngine"]),
        .library(name: "FixtureKit", targets: ["FixtureKit"]),
    ],
    targets: [
        // The only module that imports Photos/Vision (behind canImport guards).
        .target(name: "PhotoGateway"),
        // Pure logic: UIKit-free, PhotoKit-free. Enforced by having no Apple-only imports.
        .target(name: "ScanEngine", dependencies: ["PhotoGateway"]),
        // Test support: mock gateway + synthetic fixture libraries.
        .target(name: "FixtureKit", dependencies: ["PhotoGateway", "ScanEngine"]),
        .testTarget(name: "ScanEngineTests", dependencies: ["ScanEngine", "FixtureKit"]),
    ]
)
