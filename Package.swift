// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "KeyDepthMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KeyDepthMonitor", targets: ["KeyDepthMonitor"])
    ],
    targets: [
        .executableTarget(
            name: "KeyDepthMonitor",
            path: "Sources/KeyDepthMonitor"
        ),
        .testTarget(
            name: "KeyDepthMonitorTests",
            dependencies: ["KeyDepthMonitor"],
            path: "Tests/KeyDepthMonitorTests"
        )
    ]
)
