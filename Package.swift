// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Agenticious",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.11.2")),
    ],
    targets: [
        .executableTarget(
            name: "Agenticious",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            // AppIcon.png is the artwork the design scripts draw the bundle icon from; the app doesn't show it.
            exclude: ["Resources/AppIcon.png"],
            resources: [.copy("Resources/task-presets.json"), .copy("Resources/BundleIcon.png"), .copy("Resources/ClaudeIcon.png"), .copy("Resources/CodexIcon.svg"), .copy("Resources/Summon.wav")]
        ),
        .executableTarget(name: "agenticious-mcp"),
        .testTarget(name: "AgenticiousTests", dependencies: ["Agenticious"]),
    ]
)
