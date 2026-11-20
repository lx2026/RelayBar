// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RelayTransport",
    platforms: [.macOS(.v14), .iOS("27.0")],
    products: [.library(name: "RelayTransport", targets: ["RelayTransport"]),
               .library(name: "RelayWebRoutes", targets: ["RelayWebRoutes"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.105.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
    ],
    targets: [
        .target(name: "RelayTransport", dependencies: [
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ]),
        .target(name: "RelayWebRoutes", dependencies: [
            "RelayTransport",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
        .testTarget(name: "RelayTransportTests", dependencies: [
            "RelayWebRoutes",
            .product(name: "NIOPosix", package: "swift-nio"),
            "RelayTransport",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
        ]),
    ]
)
