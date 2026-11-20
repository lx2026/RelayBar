// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Frame",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Frame", targets: ["Frame"])
    ],
    dependencies: [.package(path: "../../Packages/AppComposition")],
    targets: [
        .target(name: "FrameKit", dependencies: [
            .product(name: "Composition", package: "AppComposition"), .product(name: "PreviewSupport", package: "AppComposition"), .product(name: "BridgeProtocol", package: "AppComposition"),
            .product(name: "AssetGrouping", package: "AppComposition"), .product(name: "MarkdownRendering", package: "AppComposition"),
            .product(name: "HouseStyle", package: "AppComposition")
        ]),
        .executableTarget(
            name: "Frame",
            dependencies: ["FrameKit", .product(name: "Composition", package: "AppComposition"), .product(name: "PreviewSupport", package: "AppComposition"), .product(name: "BridgeProtocol", package: "AppComposition"), .product(name: "AssetGrouping", package: "AppComposition"), .product(name: "HouseStyle", package: "AppComposition")]
        ),
        .testTarget(
            name: "FrameKitTests",
            dependencies: ["Frame", "FrameKit", .product(name: "CompositionFixtures", package: "AppComposition"), .product(name: "Composition", package: "AppComposition"), .product(name: "PreviewSupport", package: "AppComposition"), .product(name: "BridgeProtocol", package: "AppComposition"), .product(name: "AssetGrouping", package: "AppComposition"), .product(name: "MarkdownRendering", package: "AppComposition"), .product(name: "HouseStyle", package: "AppComposition")],
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v5]
)
