import Foundation
import Combine

@MainActor
final class TaskPresetStore: ObservableObject {
    @Published private(set) var presets = TaskTemplate.defaults
    @Published private(set) var loadError: String?
    let url: URL

    init(url: URL = TaskPresetStore.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let saved = try JSONDecoder().decode([TaskTemplate].self, from: Data(contentsOf: url))
            try validate(saved)
            presets = saved
        } catch {
            loadError = "Could not load presets: \(error.localizedDescription). Your saved file has been preserved."
        }
    }

    nonisolated static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/task-presets.json")
    }

    func preset(id: String) -> TaskTemplate { presets.first { $0.id == id } ?? presets.first { $0.isCustom } ?? .custom }

    func save(_ preset: TaskTemplate) throws {
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) { updated[index] = preset }
        else { updated.append(preset) }
        try persist(updated)
    }

    func remove(_ preset: TaskTemplate) throws {
        guard !preset.isCustom else { throw ConfigurationError("The custom task cannot be deleted.") }
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

struct ConfigurationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
