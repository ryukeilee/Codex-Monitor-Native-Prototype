// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexMonitorNative",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodexMonitorNative",
            targets: ["CodexMonitorNative"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexMonitorNative",
            path: "Sources/CodexMonitorNative"
        ),
        .testTarget(
            name: "CodexMonitorNativeTests",
            dependencies: ["CodexMonitorNative"],
            path: "Tests/CodexMonitorNativeTests"
        )
    ]
)
