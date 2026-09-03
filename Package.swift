// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "local-port-monitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PortMonitorCore", targets: ["PortMonitorCore"]),
        .executable(name: "local-port-monitor", targets: ["LocalPortMonitorApp"])
    ],
    targets: [
        .target(
            name: "PortMonitorCore",
            path: "Sources/PortMonitorCore"
        ),
        .executableTarget(
            name: "LocalPortMonitorApp",
            dependencies: ["PortMonitorCore"],
            path: "Sources/LocalPortMonitorApp"
        ),
        .testTarget(
            name: "PortMonitorCoreTests",
            dependencies: ["PortMonitorCore", "LocalPortMonitorApp"],
            path: "Tests/PortMonitorCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
