// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macos-screencap-mcp",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "macos-screencap-mcp", path: "Sources/macos-screencap-mcp")
    ],
    swiftLanguageModes: [.v5]
)
