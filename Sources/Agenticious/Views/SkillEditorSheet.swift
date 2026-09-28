import SwiftUI

struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    var skill: InstalledSkill?
    let saved: (URL) -> Void
    @State private var name = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var original: String?
    @State private var destination = "codex"
    @State private var projectOnly = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(skill == nil ? "Create a skill" : "Edit skill", systemImage: "sparkles")
                .font(.system(size: 26, weight: .bold, design: .rounded))
            if let skill {
                Text(skill.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Edit the complete file. Existing metadata and supporting files are preserved.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                TextField("Skill name (e.g. review-accessibility)", text: $name)
                TextField("Description: what it does and when to use it", text: $summary)
                HStack {
                    Picker("Agent", selection: $destination) {
                        Text("Codex").tag("codex")
                        Text("Claude Code").tag("claude")
                    }
                    Toggle("Only this project", isOn: $projectOnly).disabled(project.path == nil)
                }
                Text(destinationRoot.path).font(.caption).foregroundStyle(AgenticiousStyle.violet).textSelection(.enabled)
            }
            Text(skill == nil ? "Instructions" : "SKILL.md").font(.headline)
            TextEditor(text: $instructions)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Skill instructions")
            if let error { Text(error).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AgenticiousButtonStyle(isPrimary: false)).keyboardShortcut(.cancelAction)
                Button(skill == nil ? "Create skill" : "Save skill", action: save)
                    .buttonStyle(AgenticiousButtonStyle())
                    .disabled(skill != nil && original == nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 740, height: 620)
        .background(AgenticiousStyle.ink)
        .preferredColorScheme(.dark)
        .tint(AgenticiousStyle.lime)
        .task {
            guard let skill else { return }
            do { let text = try SkillDocument.read(skill.url).text; original = text; instructions = text }
            catch { self.error = error.localizedDescription }
        }
    }

    private var destinationRoot: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if projectOnly, let path = project.path {
            return URL(fileURLWithPath: path).appendingPathComponent(destination == "codex" ? ".agents/skills" : ".claude/skills")
        }
        if destination == "claude" { return home.appendingPathComponent(".claude/skills") }
        return home.appendingPathComponent(".agents/skills")
    }

    private func save() {
        do {
            let url: URL
            if let skill, let original {
                guard skill.isEditable else { throw ConfigurationError("Plugin cache skills are read-only.") }
                try SkillFiles().save(instructions, to: skill.url, original: original)
                url = skill.url
            } else {
                url = try SkillFiles().create(name: name, description: summary, instructions: instructions, root: destinationRoot)
            }
            saved(url)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
