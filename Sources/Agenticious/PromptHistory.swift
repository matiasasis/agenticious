import Foundation
import Combine

/// A task input that started an agent or chat.
struct RecentInput: Codable, Equatable, Identifiable {
    let text: String
    let usedAt: Date

    /// Unique within a preset: the same text used again replaces its earlier entry.
    var id: String { text }
}

/// The task inputs started with each preset, most recent first. Kept apart from the file so its rules test on their own.
struct PromptHistoryLog: Codable, Equatable {
    static let limit = 20

    private(set) var inputs: [String: [RecentInput]] = [:]

    func recent(for presetID: String) -> [RecentInput] { inputs[presetID] ?? [] }

    /// Order is the order of use, not of `usedAt`: a clock that moved back can't shuffle the list. False for an empty input.
    @discardableResult
    mutating func record(_ input: String, for presetID: String, at date: Date) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var list = recent(for: presetID).filter { $0.text != text }
        list.insert(RecentInput(text: text, usedAt: date), at: 0)
        inputs[presetID] = Array(list.prefix(Self.limit))
        return true
    }

    mutating func remove(_ text: String, for presetID: String) {
        let list = recent(for: presetID).filter { $0.text != text }
        inputs[presetID] = list.isEmpty ? nil : list
    }

    /// Drops the history of presets that were deleted.
    mutating func prune(keeping presetIDs: Set<String>) {
        inputs = inputs.filter { presetIDs.contains($0.key) }
    }

    /// How long ago, in the few words a small box has room for.
    static func age(of date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 0 || seconds < 12 * 3600 { return "\(Int(seconds / 3600)) h ago" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
    }
}

/// Remembers the task inputs used with each preset, so the Summon sheet can offer them again. Stays on this Mac:
/// it isn't in what the Stream Deck plugin or hooks are told.
@MainActor
final class PromptHistory: ObservableObject {
    nonisolated static let shown = 5

    let url: URL
    /// The presets that exist; nil while that isn't known (the presets file didn't load), so nothing is dropped on a guess.
    private let presetIDs: () -> Set<String>?
    /// Read the first time it's needed: a store built in a test or by the app doesn't touch the file until the sheet opens.
    private lazy var log = load()

    init(url: URL = PromptHistory.defaultURL, presetIDs: @escaping () -> Set<String>? = { nil }) {
        self.url = url
        self.presetIDs = presetIDs
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/prompt-history.json")
    }

    func recent(for presetID: String, limit: Int = PromptHistory.shown) -> [RecentInput] {
        Array(log.recent(for: presetID).prefix(limit))
    }

    func record(_ input: String, for presetID: String, at date: Date = .now) {
        var updated = log
        guard updated.record(input, for: presetID, at: date) else { return }
        objectWillChange.send()
        log = updated
        save()
    }

    func remove(_ text: String, for presetID: String) {
        objectWillChange.send()
        log.remove(text, for: presetID)
        save()
    }

    /// History is a convenience: a missing or unreadable file is no history, and the next save replaces it.
    private func load() -> PromptHistoryLog {
        guard var saved = try? Self.decoder.decode(PromptHistoryLog.self, from: Data(contentsOf: url)) else { return PromptHistoryLog() }
        if let ids = presetIDs() { saved.prune(keeping: ids) }
        return saved
    }

    /// Never throws: failing to remember an input mustn't stand in the way of the agent it started.
    private func save() {
        if let ids = presetIDs() { log.prune(keeping: ids) }
        guard let data = try? Self.encoder.encode(log) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
