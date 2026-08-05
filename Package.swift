// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDock"])
    ],
    targets: [
        .executableTarget(
            name: "RelayDock",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network")
            ]
        ),
        .testTarget(
            name: "RelayDockTests",
            dependencies: ["RelayDock"]
        )
    ],
    swiftLanguageModes: [.v5]
)
