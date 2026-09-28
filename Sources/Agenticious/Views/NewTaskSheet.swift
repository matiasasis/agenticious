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
        VStack(spacing: 0) {
            header
            TaskTemplatePicker(selection: $template)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    missionFields
                    configurationFields
                    if let launchError {
                        Label(launchError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red).font(.callout)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            footer
        }
        .frame(width: 760, height: 700)
        .background(AgenticiousStyle.ink)
        .tint(AgenticiousStyle.lime)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(AgenticiousStyle.lime)
                .frame(width: 56, height: 56)
                .background(AgenticiousStyle.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text("Summon an agent")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Choose a skill. Give it a mission. Let the magic happen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(24)
        .background(AgenticiousStyle.panel)
    }

    @ViewBuilder
    private var missionFields: some View {
        if template == .custom {
            VStack(alignment: .leading, spacing: 8) {
                Text("The mission").font(.headline)
                editor($task, minHeight: 140)
                    .accessibilityLabel("Task")
                Text("Describe the outcome. Your agent will break it into steps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(template.fieldLabel).font(.headline)
                    TextField(template.fieldPlaceholder, text: $templateValue)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .padding(12)
                        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
                        .accessibilityLabel(template.fieldLabel)
                    Text("Title: \(template.title(for: trimmedValue.isEmpty && template.isFieldRequired ? "…" : trimmedValue))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Notes (optional)").font(.headline)
                editor($notes, minHeight: 90)
                    .accessibilityLabel("Notes (optional)")
            }
        }
    }

    private var configurationFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Agent & workspace", systemImage: "slider.horizontal.3")
                .font(.headline).foregroundStyle(AgenticiousStyle.violet)
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
                    .buttonStyle(AgenticiousButtonStyle(isCompact: true))
            }
            if isGitProject {
                Toggle("Run in its own git worktree", isOn: $useWorktree)
                    .help("Creates \(Worktrees.folder)/<task> on a new agenticious/<task> branch from the current HEAD, so agents in the same repo don't edit the same files.")
            }
        }
        .padding(18)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("⌘ Return to summon")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(AgenticiousButtonStyle(isPrimary: false))
            Button("Start agent", systemImage: "sparkles", action: start)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(AgenticiousButtonStyle())
                .disabled(!canStart)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AgenticiousStyle.panel)
        .overlay(alignment: .top) { Rectangle().fill(AgenticiousStyle.violet.opacity(0.2)).frame(height: 1) }
    }

    private func editor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(minHeight: minHeight)
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AgenticiousStyle.violet.opacity(0.3)))
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

private struct TaskTemplatePicker: View {
    @Binding var selection: TaskTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a skill").font(.headline)
            HStack(spacing: 8) {
                ForEach(TaskTemplate.allCases) { template in
                    Button { selection = template } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: template.symbol).font(.title3)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .opacity(selection == template ? 1 : 0)
                            }
                            Text(template.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(selection == template ? AgenticiousStyle.lime : .primary)
                        .background(selection == template ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.panel,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12)
                            .stroke(selection == template ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.25)))
                        .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(template.name)
                    .accessibilityValue(selection == template ? "Selected" : "Not selected")
                    .accessibilityAddTraits(selection == template ? .isSelected : [])
                    .help(template.summary)
                }
            }
            Text(selection.summary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
