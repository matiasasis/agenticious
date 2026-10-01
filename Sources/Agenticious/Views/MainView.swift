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
                .safeAreaInset(edge: .top, spacing: 0) { ControlRoomBar(project: defaultProject) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AgenticiousStyle.ink)
        }
        .tint(AgenticiousStyle.lime)
        .preferredColorScheme(.dark)
        .sheet(item: $store.composer) { NewTaskSheet(project: $0.project, template: $0.template) }
        .alert(store.alert ?? "", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("OK") {}
                .tint(AgenticiousStyle.lime)
        }
        .onAppear(perform: launchFromCommandLine)
    }

    @ViewBuilder
    private var detail: some View {
        if store.selection == .providers {
            ProvidersView()
        } else if [.settings, .skills, .preferences].contains(store.selection) {
            CustomizeView()
        } else if let session = store.selectedSession {
            SessionDetailView(session: session)
                .id(session.id)
        } else {
            OverviewView()
        }
    }

    /// New agents default to the project of whatever you're looking at.
    private var defaultProject: Project {
        store.composerProject
    }

    private func launchFromCommandLine() {
        guard let options = store.takeCommandLineOptions() else { return }
        if let template = options.newAgentTemplate { store.composer = Composer(project: defaultProject, template: store.presets.preset(id: template)) }
        if options.showSettings { store.selection = .settings }
        if options.showPreferences { store.selection = .preferences }
        if options.showSkills { store.selection = .skills }
        if options.showProviders { store.selection = .providers }
        if options.showFinished { store.show(.finished) }
        if let id = options.sessionToShow, store.session(id) != nil { store.selection = .session(id) }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 6) {
                    ForEach(AgentList.allCases) { list in
                        Button { store.show(list) } label: {
                            HStack(spacing: 6) {
                                Text(list.title)
                                Text("\(store.count(in: list))").monospacedDigit().opacity(0.7)
                            }
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .foregroundStyle(store.agentList == list ? AgenticiousStyle.lime : .secondary)
                            .background(store.agentList == list ? AgenticiousStyle.lime.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(store.agentList == list ? .isSelected : [])
                    }
                }
                .padding(4).background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 14))
                if store.visibleSessions.isEmpty {
                    Text(store.agentList == .queue ? "Queue clear. Summon an agent to get started." : "Agents you mark as finished will appear here.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                HStack {
                    Text("WORKSPACES").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(1)
                    Spacer()
                    Button("Add project folder…", systemImage: "folder.badge.plus", action: addProject)
                        .labelStyle(.iconOnly).buttonStyle(.plain).help("Add project folder")
                }.foregroundStyle(.secondary).padding(.horizontal, 4)
                ForEach(store.visibleProjectGroups) { group in
                    let isCollapsed = collapsed.contains(group.id)
                    VStack(spacing: 8) {
                        ProjectHeader(group: group, isCollapsed: isCollapsed) {
                            if isCollapsed { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
                        }
                        if !isCollapsed {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, isSelected: store.selection == .session(session.id))
                                    .contextMenu { SessionMenu(session: session) }
                            }
                        }
                    }
                }
            }.padding(12)
        }
        .background(AgenticiousStyle.ink)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                if let icon = Bundle.module.url(forResource: "AppIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:)) {
                    Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("AGENTICIOUS").font(.system(size: 17, weight: .black, design: .rounded))
                    Text("A LITTLE CHAOS. A LOT DONE.")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(1).foregroundStyle(AgenticiousStyle.lime)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .safeAreaInset(edge: .bottom) {
            Button { store.selection = .settings } label: {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3").font(.title3).foregroundStyle(AgenticiousStyle.violet)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Customize").font(.callout.weight(.semibold))
                        Text("Task presets, skills & preferences").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(AgenticiousStyle.violet.opacity(0.25)))
            }
            .buttonStyle(.plain).padding(12)
            .background(AgenticiousStyle.ink)
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
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if !group.sessions.isEmpty {
                        Text("\(group.sessions.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.project.path ?? "Ideas and questions that don't need a codebase")

            Spacer()

            Button("Summon agent", systemImage: "plus") { store.composer = Composer(project: group.project) }
                .fixedSize()
                .buttonStyle(AgenticiousButtonStyle(isCompact: true))
                .help("Summon an agent in \(group.project.name)")
        }
        .padding(.horizontal, 2)
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
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: AgentSession
    let isSelected: Bool
    @AppStorage("sidebarShowBranches") private var showBranches = true
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.selection = .session(session.id) } label: {
                details.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if session.isMarkedFinished || session.canMarkFinished {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        store.markFinished(session, finished: !session.isMarkedFinished)
                    } label: {
                        Label(session.archiveActionTitle, systemImage: session.archiveActionSymbol)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .foregroundStyle(AgenticiousStyle.lime)
                            .background(AgenticiousStyle.lime.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(session.isArchiving)
                    .help("Keep history and clean up resources. Worktrees with uncommitted changes are preserved.")
                }
            }
        }
        .padding(12)
        .background(session.status.color.opacity(isSelected ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 12))
        .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(session.status.color.opacity(isSelected ? 1 : isHovered ? 0.8 : 0.45), lineWidth: isSelected ? 2 : 1))
        .backgroundTask(session.backgroundTask, isCompact: true)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovered = $0 }
        .help(session.task)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            TaskHeading(type: session.displayedTaskType, task: session.task, size: .compact)
            if !session.startupSteps.isEmpty {
                StartupProgressView(steps: session.startupSteps, isCompact: true)
            }
            if !session.chunks.isEmpty {
                HStack(spacing: 8) {
                    ChunkStrip(chunks: session.chunks, style: .compact, isRunning: session.isRunning)
                    Text("\(session.completedChunks)/\(session.chunks.count)")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            if showBranches, let worktree = session.worktree {
                BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved)
            }
            if case let .needsYou(reason) = session.status {
                Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var header: some View {
        let badge = AgentBadge(agent: session.agent, detail: session.modelSummary)
        let status = HStack(spacing: 6) {
            StatusDot(status: session.status)
            Text(session.status.label).foregroundStyle(session.status.color)
        }.font(.system(size: 10, weight: .semibold))

        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                badge.fixedSize()
                Spacer(minLength: 4)
                status.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                badge
                status
            }
        }
    }
}

struct SessionMenu: View {
    @EnvironmentObject private var store: SessionStore
    let session: AgentSession

    var body: some View {
        Button(session.isMarkedFinished ? "Retry archive cleanup" : "Archive agent", systemImage: "archivebox") { store.archive(session) }
            .disabled(session.isArchiving)
        if !session.status.isFinished && !session.isMarkedFinished {
            Button("Mark as ended", systemImage: "stop.circle") { store.markEnded(session) }
                .disabled(session.isArchiving)
                .help("Record that work was stopped or handed off. Archive to stop processes and clean up resources.")
        }
        if session.canStop {
            Button("Stop agent") { store.stop(session) }
                .disabled(session.isArchiving)
        } else if !session.isRunning {
            Button("Resume") { store.resume(session) }
                .disabled(!session.canResume)
        }
        if session.worktree != nil && !session.worktreeRemoved {
            Button("Delete worktree") { store.deleteWorktree(of: session) }
                .disabled(session.isRunning || session.isArchiving)
                .help("Stop the agent first; git refuses if there are uncommitted changes.")
        }
        Button("Remove", role: .destructive) { store.remove(session) }
            .disabled(session.isArchiving)
    }
}

// MARK: - Overview

private struct OverviewView: View {
    @EnvironmentObject private var store: SessionStore

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if store.agentList == .queue {
                    ControlRoomHero(isEmpty: store.visibleSessions.isEmpty)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Finished agents").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Finished and archived agents. Open any agent to revisit its history.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let error = store.serverError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                if store.visibleSessions.isEmpty {
                    Label(store.agentList == .queue ? "No agents in your queue. Finished work is saved in the Finished tab." : "No finished agents yet.", systemImage: "sparkles")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(store.visibleProjectGroups.filter { !$0.sessions.isEmpty }) { group in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label(group.project.name, systemImage: group.project.symbol)
                                .font(.title3.bold())
                            Rectangle().fill(AgenticiousStyle.violet.opacity(0.25)).frame(height: 1)
                            Text("\(group.sessions.count) AGENTS")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(group.sessions) { session in
                                Button { store.selection = .session(session.id) } label: {
                                    SessionCard(session: session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { SessionMenu(session: session) }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct SessionCard: View {
    @ObservedObject var session: AgentSession
    @State private var isHovered = false

    private static let stepRows = 5
    private let titleFont = Font.title3.weight(.semibold)

    var body: some View {
        // Drawn over an invisible worst-case card, so every card has the same height and long content is cut, not grown.
        sizingCard.hidden()
            .overlay(alignment: .top) { content }
            .padding(20)
            .background(session.status.color.opacity(isHovered ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 18))
            .background(AgenticiousStyle.panel, in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(session.status.color.opacity(isHovered ? 0.8 : 0.45), lineWidth: 1)
            )
            .shadow(color: session.status.color.opacity(isHovered ? 0.14 : 0), radius: 16)
            .backgroundTask(session.backgroundTask)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .onHover { isHovered = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header
                TaskHeading(type: session.displayedTaskType, task: session.task)
                if !session.startupSteps.isEmpty {
                    StartupProgressView(steps: session.startupSteps)
                } else if session.startupPrompt == nil {
                    ChunkStrip(chunks: session.chunks, style: .compact, isRunning: session.isRunning)
                    ChunkList(chunks: session.chunks, limit: Self.stepRows)
                }
                if case let .needsYou(reason) = session.status {
                    Label(reason, systemImage: "hand.raised.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(reason)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 12) {
                if let worktree = session.worktree { BranchLabel(worktree: worktree, isRemoved: session.worktreeRemoved) }
                footer
            }
        }
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private var sizingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 10) {
                TaskTypeIcon(type: session.displayedTaskType)
                VStack(alignment: .leading, spacing: 4) {
                    Text(" ").font(titleFont).lineLimit(2, reservesSpace: true)
                    Text(" ").font(.callout).lineLimit(3, reservesSpace: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ChunkStrip(chunks: [], style: .compact)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<Self.stepRows, id: \.self) { _ in Label(" ", systemImage: "circle").font(.callout) }
            }
            Label(" ", systemImage: "hand.raised.fill").font(.callout).lineLimit(2, reservesSpace: true)
            Label(" ", systemImage: "arrow.triangle.branch").font(.caption)
            footer
        }
    }

    private var header: some View {
        HStack {
            AgentBadge(agent: session.agent, detail: session.modelSummary)
            Spacer()
            StatusPill(status: session.status)
        }
    }

    private var footer: some View {
        HStack {
            Text(session.startedAt, style: .relative)
            Spacer()
            if !session.chunks.isEmpty { Text("\(session.completedChunks)/\(session.chunks.count) steps") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
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
