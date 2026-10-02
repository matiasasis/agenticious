import Foundation
import Combine

@MainActor
final class TaskPresetStore: ObservableObject {
    @Published private(set) var presets = TaskTemplate.defaults
    @Published private(set) var loadError: String?
    let url: URL
    private let defaults: UserDefaults
    private static let usesKey = "taskPresetUses"
    private static let orderKey = "taskPresetOrder"

    init(url: URL = TaskPresetStore.defaultURL, defaults: UserDefaults = .standard) {
        self.url = url
        self.defaults = defaults
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode([TaskTemplate].self, from: Data(contentsOf: url))
            try validate(saved)
            presets = saved
            if !presets.contains(where: \.isChat) { presets.insert(.chat, at: min(1, presets.count)) }
        } catch {
            loadError = "Could not load presets: \(error.localizedDescription). Your saved file has been preserved."
        }
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/task-presets.json")
    }

    func preset(id: String) -> TaskTemplate { presets.first { $0.id == id } ?? presets.first { $0.isCustom } ?? .custom }

    var order: TaskPresetOrder {
        get { defaults.string(forKey: Self.orderKey).flatMap(TaskPresetOrder.init) ?? .mostUsed }
        set {
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.orderKey)
        }
    }

    var offeredPresets: [TaskTemplate] { order == .arranged ? presets : presetsByUse }

    /// The custom task first, then the most started; ties keep the saved order.
    private var presetsByUse: [TaskTemplate] {
        let uses = defaults.dictionary(forKey: Self.usesKey) as? [String: Int] ?? [:]
        return presets.enumerated()
            .sorted { a, b in
                if a.element.isCustom != b.element.isCustom { return a.element.isCustom }
                let (left, right) = (uses[a.element.id] ?? 0, uses[b.element.id] ?? 0)
                return left != right ? left > right : a.offset < b.offset
            }
            .map(\.element)
    }

    func recordUse(of preset: TaskTemplate) {
        var uses = defaults.dictionary(forKey: Self.usesKey) as? [String: Int] ?? [:]
        uses[preset.id, default: 0] += 1
        defaults.set(uses, forKey: Self.usesKey)
        objectWillChange.send()
    }

    func save(_ preset: TaskTemplate) throws {
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) { updated[index] = preset }
        else { updated.append(preset) }
        try persist(updated)
    }

    /// Moves the preset so it sits at `index`, clamped to either end; unknown IDs are ignored.
    func move(id: String, to index: Int) throws {
        guard let current = presets.firstIndex(where: { $0.id == id }) else { return }
        var updated = presets
        let moved = updated.remove(at: current)
        updated.insert(moved, at: min(max(index, 0), updated.count))
        try persist(updated)
    }

    func remove(_ preset: TaskTemplate) throws {
        guard !preset.isCustom, !preset.isChat else { throw ConfigurationError("The custom task and Chat cannot be deleted.") }
        try persist(presets.filter { $0.id != preset.id })
    }

    private func persist(_ updated: [TaskTemplate]) throws {
        if let loadError { throw ConfigurationError(loadError) }
        try validate(updated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        presets = updated
    }

    private func validate(_ values: [TaskTemplate]) throws {
        guard values.filter(\.isCustom).count == 1, Set(values.map(\.id)).count == values.count else {
            throw ConfigurationError("Presets must have unique IDs and one custom task.")
        }
        for value in values {
            if let message = value.validationMessage { throw ConfigurationError(message) }
        }
    }
}

enum TaskPresetOrder: String, CaseIterable, Identifiable {
    case mostUsed
    case arranged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostUsed: "Most used"
        case .arranged: "As arranged"
        }
    }
}

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
