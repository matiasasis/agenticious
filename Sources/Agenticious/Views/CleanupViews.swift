import SwiftUI

/// What runs when this agent is ended or archived: its own registered tasks, then its workspace's commands.
struct CleanupTaskList: View {
    @ObservedObject var session: AgentSession
    @State private var isExpanded = false

    private var workspaceTasks: [CleanupTask] { WorkspaceCleanup.tasks(for: session.project) }

    var body: some View {
        let workspace = workspaceTasks
        let count = session.cleanupTasks.count + workspace.count
        if count > 0, !session.isMarkedFinished {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.cleanupTasks) { task in
                        row(task, source: "From the agent") { session.cleanupTasks.removeAll { $0 == task } }
                    }
                    ForEach(workspace) { row($0, source: "Workspace", remove: nil) }
                }
                .padding(.top, 6)
            } label: {
                Label("\(count) cleanup \(count == 1 ? "task runs" : "tasks run") when this agent ends", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .tint(AgenticiousStyle.violet)
        }
    }

    private func row(_ task: CleanupTask, source: String, remove: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.caption.weight(.semibold))
                Text(task.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(AgenticiousStyle.lime)
                    .textSelection(.enabled).lineLimit(3)
            }
            Spacer()
            Text(source).font(.caption2).foregroundStyle(.secondary)
            if let remove {
                Button("Don't run this", systemImage: "xmark.circle", action: remove)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Remove this cleanup task")
            }
        }
        .padding(8)
        .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Edits the commands that run for every agent in a workspace when it is ended or archived.
struct WorkspaceCleanupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cleanup for \(project.name)").font(.title3.weight(.bold))
            Text("""
                One command per line. They run for every agent in this workspace when it is ended, marked as finished, \
                or archived: after the agent stops and before its worktree is removed, in its working directory. \
                Agents also register their own cleanup for what they create. Lines starting with # are skipped.
                """)
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(AgenticiousStyle.ink, in: RoundedRectangle(cornerRadius: 8))
                .frame(minHeight: 160)
            Text("Available: $AGENTICIOUS_WORKTREE, $AGENTICIOUS_BRANCH, $AGENTICIOUS_DIRECTORY, $AGENTICIOUS_PROJECT, $AGENTICIOUS_SESSION. Each command gets two minutes.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(AgenticiousButtonStyle(isPrimary: false))
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    WorkspaceCleanup.setText(text, for: project)
                    dismiss()
                }
                .buttonStyle(AgenticiousButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { text = WorkspaceCleanup.text(for: project) }
    }
}
