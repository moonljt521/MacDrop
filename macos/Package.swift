// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MoonDrop",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MoonDrop",
            path: "Sources/MoonDrop"
        )
    ]
)