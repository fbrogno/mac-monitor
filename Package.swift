// swift-tools-version: 6.0
import PackageDescription

// The shipped app is built from project.yml (XcodeGen). This package provides the tested
// MonitorCore library and a SwiftPM build of the UI target for `--render-docs`.
let package = Package(
    name: "MacMonitor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MonitorCore", targets: ["MonitorCore"]),
        .library(name: "WidgetViews", targets: ["WidgetViews"]),
        .executable(name: "MacMonitor", targets: ["MacMonitor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1"),
    ],
    targets: [
        .target(name: "MonitorCore"),
        // SwiftUI views of the desktop widgets, shared by the WidgetKit extension (built from
        // project.yml) and the screenshot renderer in the app target.
        .target(name: "WidgetViews", dependencies: ["MonitorCore"]),
        .executableTarget(
            name: "MacMonitor",
            dependencies: ["MonitorCore", "WidgetViews", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ],
    swiftLanguageModes: [.v5]
)
