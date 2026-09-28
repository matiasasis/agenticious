import SwiftUI

struct NewTaskSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastAgent") private var agent: AgentKind = .claude
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("claudeEffort") private var claudeEffort = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("codexEffort") private var codexEffort = ""
    @AppStorage("useWorktree") private var useWorktree = true
    @State private var project: Project
    @State private var template: TaskTemplate
    @State private var task = ""
    @State private var templateValue = ""
    @State private var notes = ""
    @State private var launchError: String?
    @State private var catalog: [AgentKind: [ModelChoice]]

    init(project: Project, template: TaskTemplate = .custom) {
        _project = State(initialValue: project)
        _template = State(initialValue: template)
        _catalog = State(initialValue: Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, ModelCatalog.models(for: $0)) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Summon an agent", systemImage: "sparkles")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(AgenticiousStyle.lime)

            Picker("Template", selection: $template) {
                ForEach(TaskTemplate.allCases) { Text($0.name).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if template == .custom {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task").font(.headline)
                    editor($task, minHeight: 220)
                    Text("This becomes the agent's big title. The agent is told to split it into steps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(template.fieldLabel).font(.headline)
                    TextField(template.fieldPlaceholder, text: $templateValue)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    Text("Title: \(template.title(for: trimmedValue.isEmpty && template.isFieldRequired ? "…" : trimmedValue))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes (optional)").font(.headline)
                    editor($notes, minHeight: 120)
                    Text("Added to the template's instructions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                Picker("Model", selection: modelSelection) {
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: effortSelection) {
                    Text(defaultEffortName).tag("")
                    ForEach(selectedModel.efforts, id: \.self) { Text(ModelCatalog.effortName($0)).tag($0) }
                }
                .frame(maxWidth: 200)
            }

            HStack {
                Picker("Project", selection: $project) {
                    ForEach(projectChoices) { choice in
                        Label(choice.name, systemImage: choice.symbol).tag(choice)
                    }
                }
                Button("Add folder…", action: addFolder)
            }

            if isGitProject {
                Toggle("Run in its own git worktree", isOn: $useWorktree)
                    .help("Creates \(Worktrees.folder)/<task> on a new agenticious/<task> branch from the current HEAD, so agents in the same repo don't edit the same files.")
            }

            if let launchError {
                Text(launchError).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 760)
        .background(AgenticiousStyle.ink)
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .frame(minHeight: minHeight)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private var trimmedValue: String { templateValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var canStart: Bool {
        switch template {
        case .custom: !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: !template.isFieldRequired || !trimmedValue.isEmpty
        }
    }

    /// The agent's title, and what it's told when that differs (templates expand into full instructions).
    private var titleAndPrompt: (title: String, prompt: String?) {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard template != .custom else { return (trimmedTask, nil) }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = template.instructions(for: trimmedValue)
        return (template.title(for: trimmedValue), trimmedNotes.isEmpty ? instructions : "\(instructions)\n\nNotes from the human:\n\(trimmedNotes)")
    }

    /// Favorites, "No project", and the preset project in case it isn't a favorite.
    private var projectChoices: [Project] {
        var choices = store.favorites + [.none]
        if !choices.contains(project) { choices.insert(project, at: 0) }
        return choices
    }

    private var models: [ModelChoice] { catalog[agent] ?? [] }

    /// Remembered per agent. A model that's no longer offered falls back to Default.
    private var selectedModel: ModelChoice {
        let id = agent == .claude ? claudeModel : codexModel
        return models.first { $0.id == id } ?? models[0]
    }

    /// An effort the selected model doesn't support falls back to Default.
    private var selectedEffort: String {
        let effort = agent == .claude ? claudeEffort : codexEffort
        return selectedModel.efforts.contains(effort) ? effort : ""
    }

    private var modelSelection: Binding<String> {
        Binding(get: { selectedModel.id }, set: { if agent == .claude { claudeModel = $0 } else { codexModel = $0 } })
    }

    private var effortSelection: Binding<String> {
        Binding(get: { selectedEffort }, set: { if agent == .claude { claudeEffort = $0 } else { codexEffort = $0 } })
    }

    private var defaultEffortName: String {
        selectedModel.defaultEffort.map { "Default (\(ModelCatalog.effortName($0)))" } ?? "Default"
    }

    private var isGitProject: Bool {
        project.path.flatMap(Worktrees.repositoryRoot(of:)) != nil
    }

    private func addFolder() {
        if let url = FolderPicker.choose(startingAt: project.path) { project = store.addFavorite(url) }
    }

    private func start() {
        do {
            let (title, prompt) = titleAndPrompt
            try store.launch(
                task: title,
                prompt: prompt,
                agent: agent,
                model: selectedModel.isDefault ? nil : selectedModel,
                effort: selectedEffort.isEmpty ? nil : selectedEffort,
                project: project,
                isolated: isGitProject && useWorktree
            )
            dismiss()
        } catch {
            launchError = error.localizedDescription
        }
    }
}
