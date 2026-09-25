// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacTaskbar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MacTaskbar", path: "Sources/MacTaskbar")
    ]
)
