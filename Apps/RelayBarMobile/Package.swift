// swift-tools-version: 6.2
import Foundation
import PackageDescription

let checkPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
  "App/Info.plist"
).path

let checks: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let webKitPlist: [LinkerSetting] = [
  .unsafeFlags(
    [
      "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
      "-Xlinker", checkPlist,
    ], .when(platforms: [.macOS]))
]

let package = Package(
  name: "RelayBarMobile",
  platforms: [.macOS(.v14), .iOS("27.0")],
  products: [.library(name: "MobileUI", targets: ["MobileUI"])],
  dependencies: [
    .package(path: "../../Packages/AppComposition"),
    .package(path: "../../Packages/RelayTransport"),
  ],
  targets: [
    .systemLibrary(name: "CZlib"),
    .target(
      name: "MobileCore",
      dependencies: [
        "CZlib",
        .product(name: "RelayWebRoutes", package: "RelayTransport"),
        .product(name: "Composition", package: "AppComposition"),
        .product(name: "PreviewSupport", package: "AppComposition"),
        .product(name: "AssetGrouping", package: "AppComposition"),
        .product(name: "HouseStyle", package: "AppComposition"),
        .product(name: "MarkdownRendering", package: "AppComposition"),
        .product(name: "RelayTransport", package: "RelayTransport"),
      ], resources: [.copy("Workspace")], swiftSettings: checks),
    .target(
      name: "MobileUI",
      dependencies: [
        "MobileCore",
        .product(
          name: "CompositionFixtures", package: "AppComposition",
          condition: .when(platforms: [.macOS])),
      ], swiftSettings: checks),
    .executableTarget(
      name: "ScreenGallery", dependencies: ["MobileUI"], swiftSettings: checks,
      linkerSettings: webKitPlist),
    .executableTarget(
      name: "WebViewCheck",
      dependencies: [
        "MobileCore", .product(name: "CompositionFixtures", package: "AppComposition"),
      ], swiftSettings: checks, linkerSettings: webKitPlist),
    .testTarget(
      name: "MobileCoreTests", dependencies: [
        "MobileCore", "MobileUI", .product(name: "CompositionFixtures", package: "AppComposition"),
      ], swiftSettings: checks),
  ])
