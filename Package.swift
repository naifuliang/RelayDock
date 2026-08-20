// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RelayDock",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RelayDock", targets: ["RelayDock"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "RelayDock",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("Network"),
                .linkedFramework("CFNetwork"),
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
