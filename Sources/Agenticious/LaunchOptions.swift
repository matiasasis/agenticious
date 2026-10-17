import AppKit

/// Command-line options, so an agent can be started (and the UI inspected) without clicking:
///
///     Agenticious --task "Fix the flaky spec" --agent codex --model gpt-6-sol --effort high --dir ~/code/app --snapshot-dir /tmp/shots
///
/// Without `--dir` the agent runs under "No project"; without `--model` / `--effort` the CLI's defaults apply.
/// `--new-agent [template]` opens the New Agent sheet instead, e.g. `--new-agent fixCI`.
struct LaunchOptions {
    let task: String?
    let agent: AgentKind
    let model: String?
    let effort: String?
    let directory: URL?
    let snapshotDirectory: URL?
    let newAgentTemplate: String?
    let showPreferences: Bool
    let showSettings: Bool
    let showSkills: Bool
    let showProviders: Bool
    let sessionToShow: UUID?
    let showFinished: Bool
    let showDashboard: Bool

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }

        task = value("--task")
        agent = value("--agent").flatMap(AgentKind.init(rawValue:)) ?? .claude
        model = value("--model")
        effort = value("--effort")
        directory = value("--dir").map { URL(fileURLWithPath: $0) }
        snapshotDirectory = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
        showPreferences = arguments.contains("--preferences")
        showSettings = arguments.contains("--settings")
        showSkills = arguments.contains("--skills")
        showProviders = arguments.contains("--providers")
        sessionToShow = value("--session").flatMap(UUID.init(uuidString:))
        showFinished = arguments.contains("--finished")
        showDashboard = arguments.contains("--dashboard")
        newAgentTemplate = arguments.contains("--new-agent") ? value("--new-agent").flatMap { $0.hasPrefix("--") ? nil : $0 } ?? "custom" : nil
    }
}

/// Writes a PNG of every visible Agenticious window every few seconds. It renders the app's own views,
/// so it needs no Screen Recording permission.
@MainActor
final class WindowSnapshotter {
    private let directory: URL
    private var timer: Timer?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.snapshotAll() }
        }
    }

    private func snapshotAll() {
        NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }.forEach(snapshot)
    }

    private func snapshot(_ window: NSWindow) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }

        view.cacheDisplay(in: view.bounds, to: bitmap)
        let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
        let file = directory.appendingPathComponent(String(name.prefix(40)).replacingOccurrences(of: "/", with: "-") + ".png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
    }
}
