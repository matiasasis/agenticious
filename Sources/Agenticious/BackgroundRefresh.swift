import AppKit

/// A check that repeats while Agenticious is the active app, at an interval chosen in Preferences.
enum BackgroundCheck: String, CaseIterable, Identifiable {
    case providers
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .providers: "Provider connections"
        case .usage: "Usage limits"
        }
    }

    var detail: String {
        switch self {
        case .providers: "Sign-in and MCP server status for Claude Code and Codex, shown in the Providers button."
        case .usage: "Codex limits and today's Claude tokens, read from local session logs. Claude limits also update whenever a Claude agent started here replies."
        }
    }

    var reason: String {
        switch self {
        case .providers: "Servers and sign-ins rarely change, and each check runs both provider CLIs."
        case .usage: "Codex usage moves quickly while agents run, and reading the logs is cheap."
        }
    }

    /// In seconds; 0 means only when you press Refresh.
    var options: [TimeInterval] {
        switch self {
        case .providers: [3600, 3 * 3600, 6 * 3600, 12 * 3600, 24 * 3600, 0]
        case .usage: [60, 5 * 60, 15 * 60, 30 * 60, 3600]
        }
    }

    var recommended: TimeInterval {
        switch self {
        case .providers: 6 * 3600
        case .usage: 5 * 60
        }
    }

    var defaultsKey: String { rawValue + "RefreshInterval" }

    func interval(in defaults: UserDefaults = .standard) -> TimeInterval {
        defaults.object(forKey: defaultsKey) as? TimeInterval ?? recommended
    }

    func isDue(lastChecked: Date?, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        let interval = interval(in: defaults)
        guard interval > 0 else { return false }
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= interval
    }

    static func label(for interval: TimeInterval) -> String {
        switch Int(interval) {
        case 0: "Only when I press Refresh"
        case 60: "Every minute"
        case 3600: "Every hour"
        case 86_400: "Once a day"
        case let seconds where seconds % 3600 == 0: "Every \(seconds / 3600) hours"
        case let seconds: "Every \(seconds / 60) minutes"
        }
    }
}

/// Runs background checks only while Agenticious is the active app. Coming back runs anything older than its
/// interval right away; switching back and forth in between doesn't.
@MainActor
final class BackgroundRefresh {
    struct Job {
        let check: BackgroundCheck
        let lastChecked: () -> Date?
        let run: () -> Void
    }

    private let jobs: [Job]
    private let defaults: UserDefaults
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(jobs: [Job], defaults: UserDefaults = .standard) {
        self.jobs = jobs
        self.defaults = defaults
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resume() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pause() }
            },
        ]
        if NSApp?.isActive == true { resume() }
    }

    func runDueChecks(now: Date = Date()) {
        for job in jobs where job.check.isDue(lastChecked: job.lastChecked(), now: now, defaults: defaults) {
            job.run()
        }
    }

    /// Ticks well below the shortest interval, so a newly picked interval applies within half a minute.
    private func resume() {
        runDueChecks()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDueChecks() }
        }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
    }
}
