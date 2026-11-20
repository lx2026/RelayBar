// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppComposition",
    platforms: [.macOS(.v13), .iOS("27.0")],
    products: [
        .library(name: "Composition", targets: ["Composition", "CompositionUI"]),
        .library(name: "PreviewSupport", targets: ["PreviewSupport"]),
        .library(name: "CompositionFixtures", targets: ["CompositionFixtures"]),
        .library(name: "BridgeProtocol", targets: ["BridgeProtocol"]),
        .library(name: "AssetGrouping", targets: ["AssetGrouping"]),
        .library(name: "MarkdownRendering", targets: ["MarkdownRendering"]),
        .library(name: "HouseStyle", targets: ["HouseStyle"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.8.0"),
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", exact: "3.1.0"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", exact: "1.7.3")
    ],
    targets: [
        .target(name: "Composition"),
        .target(name: "CompositionUI", dependencies: ["Composition", "HouseStyle"]),
        .target(name: "HouseStyle", dependencies: ["Composition"]),
        .target(name: "PreviewSupport", dependencies: ["Composition"]),
        .target(name: "CompositionFixtures", dependencies: ["Composition"]),
        .target(name: "BridgeProtocol"),
        .target(name: "AssetGrouping", dependencies: ["PreviewSupport"]),
        .target(name: "MarkdownRendering", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            .product(name: "Highlighter", package: "HighlighterSwift"),
            .product(name: "SwiftMath", package: "SwiftMath")
        ]),
        .testTarget(name: "CompositionTests", dependencies: ["Composition", "CompositionUI", "CompositionFixtures", "PreviewSupport", "BridgeProtocol", "AssetGrouping", "HouseStyle"]),
        .testTarget(name: "MarkdownRenderingTests", dependencies: ["MarkdownRendering", "CompositionFixtures"],
                    resources: [.copy("ReferencePages")])
    ]
)
