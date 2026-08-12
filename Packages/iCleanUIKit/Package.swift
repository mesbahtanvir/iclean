// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "iCleanUIKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "iCleanUI", targets: ["iCleanUI"]),
    ],
    dependencies: [
        .package(path: "../iCleanCore"),
        .package(path: "../iCleanData"),
    ],
    targets: [
        .target(
            name: "iCleanUI",
            dependencies: [
                .product(name: "ScanEngine", package: "iCleanCore"),
                .product(name: "PhotoGateway", package: "iCleanCore"),
                .product(name: "ProposalStore", package: "iCleanData"),
                .product(name: "CommitEngine", package: "iCleanData"),
                .product(name: "Entitlements", package: "iCleanData"),
            ]
        ),
    ]
)
