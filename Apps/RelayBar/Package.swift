// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RelayBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RelayBar", targets: ["RelayBar"])
    ],
    dependencies: [
        .package(path: "../../Packages/AppComposition")
    ],
    targets: [
        .executableTarget(
            name: "RelayBar",
            dependencies: [
                .product(name: "Composition", package: "AppComposition"), .product(name: "PreviewSupport", package: "AppComposition"), .product(name: "BridgeProtocol", package: "AppComposition"),
                .product(name: "AssetGrouping", package: "AppComposition"),
                .product(name: "MarkdownRendering", package: "AppComposition")
            ],
            path: "Sources/RelayBar",
            resources: [
                .copy("Resources/THIRD_PARTY_NOTICES.txt")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "RelayBarTests",
            dependencies: ["RelayBar", .product(name: "CompositionFixtures", package: "AppComposition"), .product(name: "Composition", package: "AppComposition"), .product(name: "PreviewSupport", package: "AppComposition"), .product(name: "BridgeProtocol", package: "AppComposition"), .product(name: "AssetGrouping", package: "AppComposition"), .product(name: "MarkdownRendering", package: "AppComposition")],
            path: "Tests/RelayBarTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
