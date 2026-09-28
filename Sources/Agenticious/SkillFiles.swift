import Foundation

struct SkillFiles {
    func create(name: String, description: String, instructions: String, root: URL) throws -> URL {
        guard name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil, name.count < 64 else {
            throw ConfigurationError("Use a skill name under 64 characters with lowercase letters, numbers, and single hyphens.")
        }
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError("Add a description and instructions.")
        }
        let directory = root.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw ConfigurationError("A skill folder with this name already exists.") }
        let quotedDescription = String(decoding: try JSONEncoder().encode(description), as: UTF8.self)
        let text = "---\nname: \(name)\ndescription: \(quotedDescription)\n---\n\n\(instructions)\n"
        try validateSize(text)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("SKILL.md")
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }

    func save(_ text: String, to url: URL, original: String) throws {
        try validateSize(text)
        let document = SkillDocument(text: text)
        guard let name = document.name, !name.isEmpty, let summary = document.summary, !summary.isEmpty else {
            throw ConfigurationError("Keep the SKILL.md frontmatter with a name and description.")
        }
        guard try SkillDocument.read(url).text == original else {
            throw ConfigurationError("This skill changed on disk. Reopen it before saving so those changes are preserved.")
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func validateSize(_ text: String) throws {
        guard text.utf8.count <= 1_048_576 else { throw ConfigurationError("Skill files must be smaller than 1 MB.") }
    }

}
