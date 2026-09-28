import Foundation

/// A model an agent can run with. The empty id is "Default": no flag, so the CLI's own setting applies.
struct ModelChoice: Identifiable, Hashable {
    let id: String
    let name: String
    let efforts: [String]
    let defaultEffort: String?

    var isDefault: Bool { id.isEmpty }
}

enum ModelCatalog {
    static func models(for agent: AgentKind) -> [ModelChoice] {
        switch agent {
        case .claude: claudeModels
        case .codex: codexModels()
        }
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }

    // MARK: - Claude

    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// The aliases `claude --model` accepts; each one resolves to the latest model of that family.
    private static let claudeModels = [defaultChoice(efforts: claudeEfforts)] +
        [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")].map {
            ModelChoice(id: $0.0, name: $0.1, efforts: claudeEfforts, defaultEffort: nil)
        }

    // MARK: - Codex

    /// Codex caches the models it offers with each one's reasoning levels. List the ones its own picker lists.
    private static func codexModels() -> [ModelChoice] {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: cache),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return [defaultChoice(efforts: ["low", "medium", "high", "xhigh"])]
        }

        let listed = models
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap(codexModel)

        var allEfforts: [String] = []
        for effort in listed.flatMap(\.efforts) where !allEfforts.contains(effort) { allEfforts.append(effort) }

        return [defaultChoice(efforts: allEfforts)] + listed
    }

    private static func codexModel(_ raw: [String: Any]) -> ModelChoice? {
        guard let slug = raw["slug"] as? String else { return nil }

        let levels = raw["supported_reasoning_levels"] as? [[String: Any]] ?? []
        return ModelChoice(
            id: slug,
            name: raw["display_name"] as? String ?? slug,
            efforts: levels.compactMap { $0["effort"] as? String },
            defaultEffort: raw["default_reasoning_level"] as? String
        )
    }

    private static func defaultChoice(efforts: [String]) -> ModelChoice {
        ModelChoice(id: "", name: "Default", efforts: efforts, defaultEffort: nil)
    }
}
