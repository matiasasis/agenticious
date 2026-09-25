import AppKit

/// Command-line options, so an agent can be started (and the UI inspected) without clicking:
///
///     AgentDeck --task "Fix the flaky spec" --agent codex --dir ~/code/app --snapshot-dir /tmp/shots
///
/// Without `--dir` the agent runs under "No project".
struct LaunchOptions {
    let task: String?
    let agent: AgentKind
    let directory: URL?
    let snapshotDirectory: URL?

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    init(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }

        task = value("--task")
        agent = value("--agent").flatMap(AgentKind.init(rawValue:)) ?? .claude
        directory = value("--dir").map { URL(fileURLWithPath: $0) }
        snapshotDirectory = value("--snapshot-dir").map { URL(fileURLWithPath: $0) }
    }
}

/// Writes a PNG of every visible AgentDeck window every few seconds. It renders the app's own views,
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
