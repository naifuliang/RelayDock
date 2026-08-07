// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDock"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.2")
    ],
    targets: [
        .executableTarget(
            name: "RelayDock",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "RelayDockTests",
            dependencies: ["RelayDock"]
        )
    ],
    swiftLanguageModes: [.v5]
)
