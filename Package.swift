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
            resources: [.copy("Resources/AppIcon.png"), .copy("Resources/Mascot.png"), .copy("Resources/ClaudeIcon.png"), .copy("Resources/CodexIcon.svg")]
        ),
        .executableTarget(name: "agenticious-mcp"),
        .testTarget(name: "AgenticiousTests", dependencies: ["Agenticious"]),
    ]
)
