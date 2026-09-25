import SwiftUI

struct NewTaskSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss

    @AppStorage("lastAgent") private var agent: AgentKind = .claude
    @AppStorage("useWorktree") private var useWorktree = true
    @State private var project: Project
    @State private var task = ""
    @State private var launchError: String?

    init(project: Project) {
        _project = State(initialValue: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New agent").font(.title2.bold())

            VStack(alignment: .leading, spacing: 6) {
                Text("Task").font(.headline)
                TextEditor(text: $task)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("This becomes the agent's big title. The agent is told to split it into steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

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
                    .help("Creates \(Worktrees.folder)/<task> on a new agentdeck/<task> branch from the current HEAD, so agents in the same repo don't edit the same files.")
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
                    .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// Favorites, "No project", and the preset project in case it isn't a favorite.
    private var projectChoices: [Project] {
        var choices = store.favorites + [.none]
        if !choices.contains(project) { choices.insert(project, at: 0) }
        return choices
    }

    private var isGitProject: Bool {
        project.path.flatMap(Worktrees.repositoryRoot(of:)) != nil
    }

    private func addFolder() {
        if let url = FolderPicker.choose(startingAt: project.path) { project = store.addFavorite(url) }
    }

    private func start() {
        do {
            try store.launch(
                task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                agent: agent,
                project: project,
                isolated: isGitProject && useWorktree
            )
            dismiss()
        } catch {
            launchError = error.localizedDescription
        }
    }
}
