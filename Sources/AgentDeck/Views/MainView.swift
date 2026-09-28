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
        .sheet(item: $store.composer) { NewTaskSheet(project: $0.project) }
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
        guard let task = store.takeCommandLineTask() else { return }

        let options = LaunchOptions.current
        let project = options.directory.map { store.addFavorite($0) } ?? .none
        _ = try? store.launch(task: task, agent: options.agent, project: project)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        List(selection: $store.selection) {
            Label("All agents", systemImage: "square.grid.2x2")
                .badge(store.attentionCount)
                .tag(Selection.overview)

            ForEach(store.projectGroups) { group in
                Section {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .tag(Selection.session(session.id))
                            .contextMenu { SessionMenu(session: session) }
                    }
                } header: {
                    ProjectHeader(group: group)
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

    var body: some View {
        HStack {
            Label(group.project.name, systemImage: group.project.symbol)
                .help(group.project.path ?? "Ideas and questions that don't need a codebase")
            Spacer()
            Button("New agent here", systemImage: "plus") { store.composer = Composer(project: group.project) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
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
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
            }
            ChunkStrip(chunks: session.chunks, style: .compact)
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
        Button("Stop agent") { store.stop(session) }
        if session.worktree != nil && !session.worktreeRemoved {
            Button("Delete worktree") { store.deleteWorktree(of: session) }
                .disabled(!session.hasExited)
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
                AgentBadge(agent: session.agent)
                Spacer()
                StatusPill(status: session.status)
            }

            Text(session.task)
                .font(.title3.weight(.semibold))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            ChunkStrip(chunks: session.chunks, style: .compact)
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
        Button("Open AgentDeck", action: showMainWindow)
        Button("Quit AgentDeck") { NSApp.terminate(nil) }
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
