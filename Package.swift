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
    targets: [
        .executableTarget(
            name: "RelayBar",
            path: "Sources/RelayBar"
        ),
        .testTarget(
            name: "RelayBarTests",
            dependencies: ["RelayBar"],
            path: "Tests/RelayBarTests"
        )
    ]
)
