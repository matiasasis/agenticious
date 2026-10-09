import Foundation

struct UsageLimit: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    var hasReset: Bool { resetsAt.map { $0 < Date() } ?? false }

    /// A reading from before the window reset is stale: the window has started over.
    var currentPercent: Double { hasReset ? 0 : usedPercent }

    func reportedUsedPercent(at date: Date) -> Double? {
        guard usedPercent.isFinite, resetsAt.map({ $0 > date }) ?? true else { return nil }
        return min(max(usedPercent, 0), 100)
    }

    var windowLabel: String {
        switch windowMinutes {
        case 10080: "Week"
        case 300: "Session"
        case 0: "Limit"
        default: windowMinutes % 60 == 0 ? "\(windowMinutes / 60)h" : "\(windowMinutes)m"
        }
    }
}

/// Codex reports its account-wide limits and, separately, the limits of models with their own quota (such as Spark).
struct CodexLimits: Equatable {
    struct Model: Equatable {
        let name: String
        let limits: [UsageLimit]
    }

    var account: [UsageLimit] = []
    var models: [Model] = []

    var isEmpty: Bool { account.isEmpty && models.isEmpty }
}

struct ClaudeReading: Codable, Equatable {
    let limits: [UsageLimit]
    let takenAt: Date
}

/// Codex percentages come from local logs; model availability comes from its live usage endpoint.
/// Claude reports limits through its status line, falling back to today's token count.
@MainActor
final class UsageMonitor: ObservableObject {
    private static let claudeReadingKey = "claudeRateLimits"

    @Published private(set) var codexLimits = CodexLimits()
    @Published private(set) var codexModelQuotas: CodexModelQuotaReading?
    @Published private(set) var codexModelQuotasStale = false
    @Published private(set) var claudeReading: ClaudeReading?
    @Published private(set) var claudeTokensToday: Int?
    @Published private(set) var lastChecked: Date?
    @Published private(set) var isRefreshing = false

    init() {
        claudeReading = UserDefaults.standard.data(forKey: Self.claudeReadingKey)
            .flatMap { try? JSONDecoder().decode(ClaudeReading.self, from: $0) }
    }

    /// Today's tokens only stand in for Claude's limits, so they aren't read once a status line has reported them.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let needsTokenEstimate = claudeReading == nil
        Task.detached(priority: .utility) {
            let codex = UsageReader.codexLimits()
            let claude = needsTokenEstimate ? UsageReader.claudeTokensToday() : nil
            await MainActor.run {
                self.codexLimits = codex
                self.claudeTokensToday = claude
            }
            let modelQuotas = await CodexModelQuotaReader.read()
            await MainActor.run {
                self.recordCodexModelQuotas(modelQuotas)
                self.lastChecked = Date()
                self.isRefreshing = false
            }
        }
    }

    func recordCodexModelQuotas(_ reading: CodexModelQuotaReading?) {
        if let reading { codexModelQuotas = reading }
        codexModelQuotasStale = reading == nil
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

    private static let accountLimitID = "codex"

    /// The newest log can predate its first rate-limit line (a session that just started), and a model's own limit only
    /// shows up in sessions that used it, so look a few logs back and keep the newest reading of each limit.
    static func codexLimits(sessions: URL = home.appendingPathComponent(".codex/sessions")) -> CodexLimits {
        var readings: [CodexReading] = []
        for log in recentCodexLogs(in: sessions).prefix(5) {
            for reading in codexReadings(in: log) where !readings.contains(where: { $0.id == reading.id }) {
                readings.append(reading)
            }
        }

        return CodexLimits(account: readings.first { $0.id == accountLimitID }?.limits ?? [],
                           models: readings.filter { $0.id != accountLimitID }
                               .map { CodexLimits.Model(name: $0.name ?? $0.id, limits: $0.limits) })
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

    private struct CodexReading {
        let id: String
        let name: String?
        let limits: [UsageLimit]
    }

    /// The newest reading of each `limit_id` in the log. Older logs have no id; those lines are the account's limits.
    private static func codexReadings(in log: URL) -> [CodexReading] {
        guard let content = try? String(contentsOf: log, encoding: .utf8) else { return [] }

        var readings: [CodexReading] = []
        for line in content.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let object = parse(line),
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any] else { continue }

            let id = rateLimits["limit_id"] as? String ?? accountLimitID
            guard !readings.contains(where: { $0.id == id }) else { continue }

            let limits = ["primary", "secondary"]
                .compactMap { limit(rateLimits[$0], usedKey: "used_percent") }
                .sorted { $0.windowMinutes < $1.windowMinutes }
            if !limits.isEmpty { readings.append(CodexReading(id: id, name: rateLimits["limit_name"] as? String, limits: limits)) }
        }
        return readings
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
