import Foundation

struct UsageLimit: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var hasReset: Bool { resetsAt.map { $0 < Date() } ?? false }

    /// A reading from before the window reset is stale: the window has started over.
    var currentPercent: Double { hasReset ? 0 : usedPercent }

    var windowLabel: String {
        switch windowMinutes {
        case 10080: "Week"
        case 300: "Session"
        case 0: "Limit"
        default: windowMinutes % 60 == 0 ? "\(windowMinutes / 60)h" : "\(windowMinutes)m"
        }
    }
}

struct ClaudeReading: Codable, Equatable {
    let limits: [UsageLimit]
    let takenAt: Date
}

/// Best-effort usage readout. Neither vendor exposes a quota API, so this reads what the CLIs hand out locally:
/// Codex writes its rate-limit percentages into session logs, and Claude Code passes its session and weekly
/// usage to the status line of agents started here. Until one has run, Claude falls back to today's token count.
@MainActor
final class UsageMonitor: ObservableObject {
    private static let claudeReadingKey = "claudeRateLimits"

    @Published private(set) var codexLimits: [UsageLimit] = []
    @Published private(set) var claudeReading: ClaudeReading?
    @Published private(set) var claudeTokensToday: Int?
    private(set) var lastChecked: Date?

    init() {
        claudeReading = UserDefaults.standard.data(forKey: Self.claudeReadingKey)
            .flatMap { try? JSONDecoder().decode(ClaudeReading.self, from: $0) }
    }

    /// Today's tokens only stand in for Claude's limits, so they aren't read once a status line has reported them.
    func refresh() {
        lastChecked = Date()
        let needsTokenEstimate = claudeReading == nil
        Task.detached(priority: .utility) {
            let codex = UsageReader.codexLimits()
            let claude = needsTokenEstimate ? UsageReader.claudeTokensToday() : nil
            await MainActor.run {
                self.codexLimits = codex
                self.claudeTokensToday = claude
            }
        }
    }

    /// `rate_limits` from Claude Code's status line input: `five_hour` and `seven_day`, each `used_percentage` + `resets_at`.
    func recordClaudeRateLimits(_ rateLimits: [String: Any]) {
        let limits = [("five_hour", 300), ("seven_day", 10080)].compactMap { key, minutes in
            UsageReader.limit(rateLimits[key], usedKey: "used_percentage", windowMinutes: minutes)
        }
        guard !limits.isEmpty else { return }

        let reading = ClaudeReading(limits: limits, takenAt: Date())
        claudeReading = reading
        UserDefaults.standard.set(try? JSONEncoder().encode(reading), forKey: Self.claudeReadingKey)
    }
}

enum UsageReader {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Codex

    /// The newest log can predate its first rate-limit line (a session that just started), so look a few back.
    static func codexLimits(sessions: URL = home.appendingPathComponent(".codex/sessions")) -> [UsageLimit] {
        recentCodexLogs(in: sessions).prefix(5).lazy.compactMap(codexLimits(in:)).first ?? []
    }

    /// Logs are filed under sessions/YYYY/MM/DD by start date, so only the newest few day folders are read instead of
    /// the whole history. Several days are kept because a session started yesterday may be the one still writing.
    static func recentCodexLogs(in sessions: URL, days: Int = 3) -> [URL] {
        var folders: [URL] = []
        search: for year in subfolders(of: sessions) {
            for month in subfolders(of: year) {
                for day in subfolders(of: month) {
                    folders.append(day)
                    if folders.count == days { break search }
                }
            }
        }
        return folders
            .flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.pathExtension == "jsonl" }
            .map { ($0, modified($0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func codexLimits(in log: URL) -> [UsageLimit]? {
        guard let content = try? String(contentsOf: log, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let object = parse(line),
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            return ["primary", "secondary"]
                .compactMap { limit(limits[$0], usedKey: "used_percent") }
                .sorted { $0.windowMinutes < $1.windowMinutes }
        }
        return nil
    }

    /// Both CLIs report `resets_at` in epoch seconds. Codex includes `window_minutes`; Claude's windows are fixed.
    static func limit(_ raw: Any?, usedKey: String, windowMinutes: Int? = nil) -> UsageLimit? {
        guard let window = raw as? [String: Any], let used = window[usedKey] as? Double else { return nil }

        let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let minutes = windowMinutes ?? window["window_minutes"] as? Int ?? 0
        return UsageLimit(usedPercent: used, windowMinutes: minutes, resetsAt: resets)
    }

    // MARK: - Claude

    /// Input + output + cache-write tokens since midnight, deduplicated by message id (transcripts repeat streamed messages).
    static func claudeTokensToday() -> Int? {
        let midnight = Calendar.current.startOfDay(for: Date())
        let files = allFiles(in: home.appendingPathComponent(".claude/projects"), modifiedAfter: midnight)
        guard !files.isEmpty else { return nil }

        var seen = Set<String>()
        var total = 0
        let dateParser = ISO8601DateFormatter()
        dateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for file in files {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n") where line.contains("\"usage\"") {
                guard let object = parse(line),
                      let timestamp = (object["timestamp"] as? String).flatMap(dateParser.date(from:)), timestamp >= midnight,
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      seen.insert(message["id"] as? String ?? UUID().uuidString).inserted else { continue }

                total += ["input_tokens", "output_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
            }
        }
        return total
    }

    // MARK: - Files

    private static func parse(_ line: Substring) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    private static func allFiles(in directory: URL, modifiedAfter date: Date) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" && modified($0) >= date }
    }

    private static func subfolders(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
