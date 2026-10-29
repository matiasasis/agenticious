import Foundation

struct TaskTemplate: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var summary = ""
    var symbol = "sparkles"
    var titlePattern = "{{input}}"
    var prompt = "{{input}}"
    var skillPaths: [String] = []

    var isCustom: Bool { id == "custom" }
    var isChat: Bool { id == "chat" }
    var shortName: String { name }
    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this preset a name." }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a prompt for the agent." }
        if titlePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Add a task title." }
        return nil
    }

    func title(for value: String) -> String {
        let title = titlePattern.replacingOccurrences(of: "{{input}}", with: Self.withoutSnippets(value))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? name : title
    }

    /// Code snippets stay in the prompt but would swamp a card title.
    static func withoutSnippets(_ text: String) -> String {
        var isInSnippet = false
        return text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInSnippet.toggle()
                return false
            }
            return !isInSnippet
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func instructions(for value: String, notes: String = "") -> String {
        var result = prompt.replacingOccurrences(of: "{{input}}", with: value)
        if !prompt.contains("{{input}}"), !value.isEmpty { result += "\n\nTask input:\n\(value)" }
        if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += "\n\nNotes from the human:\n\(notes)" }
        return result
    }

    static var custom: TaskTemplate { defaults.first { $0.isCustom }! }
    static var chat: TaskTemplate { defaults.first { $0.isChat }! }
    static var defaults: [TaskTemplate] {
        let url = Bundle.module.url(forResource: "task-presets", withExtension: "json")!
        return try! JSONDecoder().decode([TaskTemplate].self, from: Data(contentsOf: url))
    }
}

struct TaskType: Codable, Equatable {
    let name: String
    let symbol: String
    let details: String?
    let templateID: String?

    var isChat: Bool { templateID == "chat" }

    init(template: TaskTemplate, input: String? = nil, notes: String = "") {
        name = template.name
        symbol = template.symbol
        templateID = template.id
        details = input.map {
            [$0, notes].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    private static let legacyPrefixes = [
        ("Implement ", "implementTicket"), ("Resolve & merge:", "reviewComments"),
        ("Address comments and merge PR ", "reviewComments"),
        ("Review PRs:", "reviewPR"), ("Review PR ", "reviewPR"), ("Review PR:", "reviewPR"),
        ("Fix CI ", "fixCI")
    ]

    func details(for title: String) -> String {
        if let details { return details }
        if let prefix = Self.legacyPrefixes.first(where: { title.hasPrefix($0.0) }),
           Self.legacy(title: title).name == name {
            return String(title.dropFirst(prefix.0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title == name ? "" : title
    }

    static func legacy(title: String) -> TaskType {
        let id = legacyPrefixes.first { title.hasPrefix($0.0) }?.1
        return TaskType(template: TaskTemplate.defaults.first { $0.id == id } ?? .custom)
    }
}
