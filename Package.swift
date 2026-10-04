// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-island",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "claude-island",
            path: "Sources/ClaudeIsland",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
