// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", .upToNextMinor(from: "1.11.2")),
    ],
    targets: [
        .executableTarget(
            name: "AgentDeck",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(name: "agentdeck-mcp"),
    ]
)
