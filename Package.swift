// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacMonitor", targets: ["MacMonitor"]),
    ],
    targets: [
        .target(name: "MonitorCore"),
        .executableTarget(name: "MacMonitor", dependencies: ["MonitorCore"]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
