import AppKit
import SwiftUI

/// One window: projects and their agents on the left; the selected agent (with its live terminal) or an overview on the right.
struct MainView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { UsageBar() }
            ToolbarItem(placement: .primaryAction) {
                Button("New Agent", systemImage: "plus") { store.composer = Composer(project: defaultProject) }
                    .keyboardShortcut("n")
            }
        }
        .sheet(item: $store.composer) { NewTaskSheet(project: $0.project, template: $0.template) }
        .alert(store.alert ?? "", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onAppear(perform: launchFromCommandLine)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = store.selectedSession {
            SessionDetailView(session: session)
                .id(session.id)
        } else {
            OverviewView()
        }
    }

    /// New agents default to the project of whatever you're looking at.
    private var defaultProject: Project {
        store.selectedSession?.project ?? store.favorites.first ?? .none
    }

    private func launchFromCommandLine() {
        guard let options = store.takeCommandLineOptions() else { return }
        if let template = options.newAgentTemplate { store.composer = Composer(project: defaultProject, template: template) }
        guard let task = options.task else { return }

        let project = options.directory.map { store.addFavorite($0) } ?? .none
        let model = options.model.map { id in
            ModelCatalog.models(for: options.agent).first { $0.id == id } ?? ModelChoice(id: id, name: id, efforts: [], defaultEffort: nil)
        }
        _ = try? store.launch(task: task, agent: options.agent, model: model, effort: options.effort, project: project)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var store: SessionStore
    @State private var collapsed: Set<Project.ID> = []

    var body: some View {
        List(selection: $store.selection) {
            Label("All agents", systemImage: "square.grid.2x2")
                .badge(store.attentionCount)
                .tag(Selection.overview)

            // Plain rows rather than Sections: a sidebar Section's collapse arrow appears on hover and shoves the + aside.
            ForEach(store.projectGroups) { group in
                let isCollapsed = collapsed.contains(group.id)

                ProjectHeader(group: group, isCollapsed: isCollapsed) {
                    if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                }

                if !isCollapsed {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .tag(Selection.session(session.id))
                            .contextMenu { SessionMenu(session: session) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button("Add project folder…", systemImage: "folder.badge.plus", action: addProject)
                .buttonStyle(.borderless)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addProject() {
        if let url = FolderPicker.choose() { _ = store.addFavorite(url) }
    }
}

private struct ProjectHeader: View {
    @EnvironmentObject private var store: SessionStore
    let group: ProjectGroup
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { if !group.sessions.isEmpty { toggle() } } label: {
                HStack(spacing: 6) {
                    // Always laid out, even with nothing to fold, so every project name lines up.
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                        .opacity(group.sessions.isEmpty ? 0 : 1)
                    Label(group.project.name, systemImage: group.project.symbol)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                    if isCollapsed && !group.sessions.isEmpty {
                        Text("\(group.sessions.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.project.path ?? "Ideas and questions that don't need a codebase")

            Spacer()

            Button("New agent here", systemImage: "plus") { store.composer = Composer(project: group.project) }
                .labelStyle(.iconOnly)
                .font(.title3.weight(.semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .buttonStyle(.borderless)
        }
        .padding(.top, 10)
        .contextMenu {
            if group.isFavorite {
                Button("Remove from favorites") { store.removeFavorite(group.project) }
            } else if let path = group.project.path {
                Button("Add to favorites") { _ = store.addFavorite(URL(fileURLWithPath: path)) }
            }
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusDot(status: session.status)
                Text(session.task)
                    .font(.title3.weight(.medium))
                    .lineLimit(2)
            }
            ChunkStrip(chunks: session.chunks, style: .compact, isRunning: session.isRunning)
            if let worktree = session.worktree { BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved) }
            if case let .needsYou(reason) = session.status {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

struct SessionMenu: View {
    @EnvironmentObject private var store: SessionStore
    let session: AgentSession

    var body: some View {
        if session.isRunning {
            Button("Stop agent") { store.stop(session) }
        } else {
            Button("Resume") { store.resume(session) }
                .disabled(!session.canResume)
        }
        if session.worktree != nil && !session.worktreeRemoved {
            Button("Delete worktree") { store.deleteWorktree(of: session) }
                .disabled(session.isRunning)
                .help("Stop the agent first; git refuses if there are uncommitted changes.")
        }
        Button("Remove", role: .destructive) { store.remove(session) }
    }
}

// MARK: - Overview

private struct OverviewView: View {
    @EnvironmentObject private var store: SessionStore

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        if store.sessions.isEmpty {
            ContentUnavailableView {
                Label("No agents running", systemImage: "square.grid.2x2")
            } description: {
                Text("Pick a project on the left and give an agent a task.")
            } actions: {
                Button("New Agent") { store.composer = Composer(project: store.favorites.first ?? .none) }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let error = store.serverError {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                    ForEach(store.projectGroups.filter { !$0.sessions.isEmpty }) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            Label(group.project.name, systemImage: group.project.symbol)
                                .font(.title3.bold())
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(group.sessions) { session in
                                    SessionCard(session: session)
                                        .onTapGesture { store.selection = .session(session.id) }
                                        .contextMenu { SessionMenu(session: session) }
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

struct SessionCard: View {
    @ObservedObject var session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                AgentBadge(agent: session.agent, detail: session.modelSummary)
                Spacer()
                StatusPill(status: session.status)
            }

            Text(session.task)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            ChunkStrip(chunks: session.chunks, style: .compact, isRunning: session.isRunning)
            ChunkList(chunks: session.chunks, limit: 5)

            if case let .needsYou(reason) = session.status {
                Label(reason, systemImage: "hand.raised.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if let worktree = session.worktree { BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved) }

            HStack {
                Text(session.startedAt, style: .relative)
                Spacer()
                if !session.chunks.isEmpty { Text("\(session.completedChunks)/\(session.chunks.count) steps") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(session.status.needsAttention ? Color.orange : Color.clear, lineWidth: 2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(store.projectGroups.flatMap(\.sessions)) { session in
            Button("\(session.status.needsAttention ? "✋ " : "")\(session.project.name): \(session.task.prefix(50))") {
                store.selection = .session(session.id)
                showMainWindow()
            }
        }
        if !store.sessions.isEmpty { Divider() }
        Button("Open Agenticious", action: showMainWindow)
        Button("Quit Agenticious") { NSApp.terminate(nil) }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum FolderPicker {
    static func choose(startingAt path: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.directoryURL = path.map { URL(fileURLWithPath: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
