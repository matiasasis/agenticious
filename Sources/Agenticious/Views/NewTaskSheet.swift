import SwiftUI
import AppKit

struct NewTaskSheet: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var presets: TaskPresetStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastTaskPreset") private var lastTaskPreset = "custom"
    @AppStorage("lastWorkspace") private var lastWorkspace = ""
    private let restoreTemplate: Bool

    @AppStorage("lastAgent") private var agent: AgentKind = .claude
    @AppStorage("claudeModel") private var claudeModel = ""
    @AppStorage("claudeEffort") private var claudeEffort = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("codexEffort") private var codexEffort = ""
    @AppStorage("useWorktree") private var useWorktree = true
    @State private var project: Project
    @State private var template: TaskTemplate
    @State private var loadedPreset = false
    @State private var showingModels = false
    @FocusState private var missionFocused: Bool
    @State private var skillPaths: [String] = []
    @State private var task = ""
    @State private var templateValue = ""
    @State private var notes = ""
    @State private var launchError: String?
    @State private var catalog: [AgentKind: [ModelChoice]]

    init(project: Project, template: TaskTemplate? = nil) {
        restoreTemplate = template == nil
        _project = State(initialValue: project)
        _template = State(initialValue: template ?? .custom)
        _catalog = State(initialValue: Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, ModelCatalog.models(for: $0)) }))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            TaskTemplatePicker(selection: $template, templates: presets.presets)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    missionFields
                    configurationFields
                    SkillSelectionField(paths: $skillPaths, project: project)
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
        .frame(width: min(960, (NSScreen.main?.visibleFrame.width ?? 1040) - 80),
               height: min(850, (NSScreen.main?.visibleFrame.height ?? 950) - 100))
        .background(AgenticiousStyle.ink)
        .tint(AgenticiousStyle.lime)
        .preferredColorScheme(.dark)
        .defaultFocus($missionFocused, true)
        .onAppear {
            guard !loadedPreset else { return }
            loadedPreset = true
            template = presets.preset(id: restoreTemplate ? lastTaskPreset : template.id)
            lastTaskPreset = template.id
            lastWorkspace = project.path ?? ""
            skillPaths = template.skillPaths
        }
        .onChange(of: template.id) { _, id in
            skillPaths = template.skillPaths
            lastTaskPreset = id
        }
        .onChange(of: project) { _, project in lastWorkspace = project.path ?? "" }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(AgenticiousStyle.lime)
                .frame(width: 44, height: 44)
                .background(AgenticiousStyle.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                Text("Summon an agent")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Choose a task. Add your skills. Let the magic happen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .background(AgenticiousStyle.panel)
    }

    @ViewBuilder
    private var missionFields: some View {
        if template.isCustom {
            VStack(alignment: .leading, spacing: 8) {
                Text("The mission").font(.headline)
                editor($task, minHeight: 100)
                    .accessibilityLabel("Task")
                    .focused($missionFocused)
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
                        .focused($missionFocused)
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
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent & workspace", systemImage: "slider.horizontal.3")
                .font(.headline).foregroundStyle(AgenticiousStyle.violet)
            HStack(spacing: 12) {
                ForEach(AgentKind.allCases) { choice in
                    Button { agent = choice } label: {
                        HStack(spacing: 8) {
                            ProviderIcon(agent: choice)
                            Text(choice.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                            Image(systemName: "checkmark.circle.fill").opacity(agent == choice ? 1 : 0)
                        }
                        .padding(.horizontal, 12).frame(height: 48)
                        .foregroundStyle(agent == choice ? AgenticiousStyle.lime : .primary)
                        .background(agent == choice ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(agent == choice ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(agent == choice ? .isSelected : [])
                }
                modelPicker
            }
            thinkingEffort
            workspacePicker
            if isGitProject {
                Toggle(isOn: $useWorktree) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundStyle(AgenticiousStyle.violet)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Give this agent its own worktree").font(.callout.weight(.semibold))
                            Text("A separate branch and folder for this mission.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .toggleStyle(.switch)
                .padding(12)
                .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
                .help("Creates \(Worktrees.folder)/<task> on a new agenticious/<task> branch from the current HEAD, so agents in the same repo don't edit the same files.")
            }
        }
        .padding(18)
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 16))
    }

    private var modelPicker: some View {
        Button { showingModels.toggle()        } label: {
            HStack(spacing: 12) {
                Image(systemName: "cpu").foregroundStyle(AgenticiousStyle.violet)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MODEL").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    Text(selectedModel.name).font(.callout.weight(.semibold))
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(AgenticiousStyle.violet)
            }
            .padding(.horizontal, 12).frame(height: 48)
            .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingModels) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a model").font(.headline).padding(8)
                    ForEach(models) { model in
                        Button {
                            modelSelection.wrappedValue = model.id
                            showingModels = false
                        } label: {
                            HStack {
                                Text(model.name)
                                Spacer()
                                if selectedModel.id == model.id { Image(systemName: "checkmark").foregroundStyle(AgenticiousStyle.lime) }
                            }
                            .padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(8)
            }.frame(width: 340, height: min(CGFloat(models.count * 40 + 60), 380))
                .background(AgenticiousStyle.panel)
        }
        .accessibilityLabel("Model")
        .accessibilityValue(selectedModel.name)
    }

    @ViewBuilder
    private var thinkingEffort: some View {
        if !selectedModel.efforts.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("THINKING EFFORT").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        effortChip("", title: defaultEffortName)
                        ForEach(selectedModel.efforts, id: \.self) { effort in
                            effortChip(effort, title: ModelCatalog.effortName(effort))
                        }
                    }.padding(1)
                }.scrollIndicators(.hidden)
            }
        }
    }

    private func effortChip(_ value: String, title: String) -> some View {
        Button { effortSelection.wrappedValue = value } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(selectedEffort == value ? AgenticiousStyle.lime : .secondary)
                .background(selectedEffort == value ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.ink, in: Capsule())
                .overlay(Capsule().stroke(selectedEffort == value ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.25)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking effort: " + title)
        .accessibilityAddTraits(selectedEffort == value ? .isSelected : [])
    }

    private var workspacePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WORKSPACE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Browse…", systemImage: "folder.badge.plus", action: addFolder)
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false, isCompact: true))
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(projectChoices) { choice in
                            SummonChoiceCard(
                                title: choice.name,
                                subtitle: choice.path.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "Ideas without a codebase",
                                symbol: choice.symbol,
                                isSelected: project == choice
                            ) { project = choice }
                            .frame(width: 200)
                            .id(choice.id)
                            .help(choice.path ?? "Run from your home folder")
                        }
                    }.padding(1)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(project.id, anchor: .center) }
                .onChange(of: project) { _, selected in proxy.scrollTo(selected.id, anchor: .center) }
            }
            if let path = project.path {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(path)
            }
        }
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
        !template.isFieldRequired || !taskInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var taskInput: String { template.isCustom ? task : templateValue }

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
            let prompt = try TaskPrompt(template: template, input: taskInput, notes: notes, skillPaths: skillPaths)
            try store.launch(
                task: prompt.title,
                prompt: prompt.instructions,
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
    let templates: [TaskTemplate]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a task").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(templates) { template in
                        Button { selection = template } label: {
                            HStack(spacing: 8) {
                                Image(systemName: template.symbol).font(.callout)
                                Text(template.shortName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Image(systemName: "checkmark.circle.fill").opacity(selection == template ? 1 : 0)
                            }
                            .padding(.horizontal, 12).frame(height: 40)
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
            }
            .scrollIndicators(.hidden)
            Text(selection.summary)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SummonChoiceCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.callout)
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(0.5))
            }
            .padding(.horizontal, 12).frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? AgenticiousStyle.lime : .primary)
            .background(isSelected ? AgenticiousStyle.lime.opacity(0.1) : AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? AgenticiousStyle.lime : AgenticiousStyle.violet.opacity(isHovered ? 0.7 : 0.25)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + ", " + subtitle)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProviderIcon: View {
    let agent: AgentKind

    private var image: NSImage {
        let name = agent == .claude ? "ClaudeIcon" : "CodexIcon"
        return Bundle.module.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    }

    var body: some View {
        Image(nsImage: image)
            .renderingMode(agent == .claude ? .template : .original)
            .resizable().scaledToFit().frame(width: 24, height: 24)
            .accessibilityHidden(true)
    }
}
