import Foundation

struct TaskPrompt {
    let title: String
    let instructions: String

    init(template: TaskTemplate, input: String, notes: String, skillPaths: [String]) throws {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw ConfigurationError("Add the task input before starting.") }
        title = template.title(for: input)
        var prompt = template.instructions(for: input, notes: notes)
        let paths = Array(Set(skillPaths)).sorted()
        if !paths.isEmpty {
            for path in paths { _ = try SkillDocument.read(URL(fileURLWithPath: path)) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let references = try paths.map { path in "- " + String(decoding: try encoder.encode(path), as: UTF8.self) }.joined(separator: "\n")
            prompt += """


            Selected skills:
            Read and apply the SKILL.md files at these absolute paths before beginning the task.
            Resolve any supporting references relative to each skill's own directory.
            If a selected skill or a required tool is unavailable, ask the human rather than silently skipping it.
            \(references)
            """
        }
        instructions = prompt
    }
}
