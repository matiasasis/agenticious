import Foundation

struct CodexLimit: Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

/// Best-effort usage readout. Neither vendor exposes a quota API, so this reads what the CLIs log locally:
/// Codex writes its real rate-limit percentages into session logs; for Claude we can only sum today's tokens.
@MainActor
final class UsageMonitor: ObservableObject {
    @Published private(set) var codexLimits: [CodexLimit] = []
    @Published private(set) var claudeTokensToday: Int?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let codex = UsageReader.codexLimits()
            let claude = UsageReader.claudeTokensToday()
            await MainActor.run {
                self.codexLimits = codex
                self.claudeTokensToday = claude
            }
        }
    }
}

enum UsageReader {
    private static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - Codex

    static func codexLimits() -> [CodexLimit] {
        guard let log = newestFile(in: home.appendingPathComponent(".codex/sessions"), modifiedAfter: .distantPast),
              let content = try? String(contentsOf: log, encoding: .utf8) else { return [] }

        for line in content.split(separator: "\n").reversed() where line.contains("\"rate_limits\":{") {
            guard let object = parse(line),
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }

            return ["primary", "secondary"].compactMap { codexLimit(limits[$0]) }
        }
        return []
    }

    private static func codexLimit(_ raw: Any?) -> CodexLimit? {
        guard let window = raw as? [String: Any], let used = window["used_percent"] as? Double else { return nil }

        let resets = (window["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return CodexLimit(usedPercent: used, windowMinutes: window["window_minutes"] as? Int ?? 0, resetsAt: resets)
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

    private static func newestFile(in directory: URL, modifiedAfter date: Date) -> URL? {
        allFiles(in: directory, modifiedAfter: date).max { modified($0) < modified($1) }
    }

    private static func allFiles(in directory: URL, modifiedAfter date: Date) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" && modified($0) >= date }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
