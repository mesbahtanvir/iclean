// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iCleanData",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ProposalStore", targets: ["ProposalStore"]),
        .library(name: "CommitEngine", targets: ["CommitEngine"]),
        .library(name: "Entitlements", targets: ["Entitlements"]),
    ],
    dependencies: [
        .package(path: "../iCleanCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "ProposalStore",
            dependencies: [
                .product(name: "ScanEngine", package: "iCleanCore"),
                .product(name: "PhotoGateway", package: "iCleanCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "CommitEngine",
            dependencies: [
                "ProposalStore",
                "Entitlements",
                .product(name: "PhotoGateway", package: "iCleanCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "Entitlements"),
        .testTarget(
            name: "ProposalStoreTests",
            dependencies: [
                "ProposalStore",
                "CommitEngine",
                .product(name: "ScanEngine", package: "iCleanCore"),
                .product(name: "PhotoGateway", package: "iCleanCore"),
            ]
        ),
    ]
)
