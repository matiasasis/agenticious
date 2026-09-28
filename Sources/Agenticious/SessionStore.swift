import AppKit
import Combine
import SwiftTerm

enum Selection: Hashable {
    case overview
    case settings
    case preferences
    case skills
    case providers
    case session(UUID)
}

enum AgentList: String, CaseIterable, Identifiable {
    case queue, finished

    var id: Self { self }
    var title: String { self == .queue ? "Queue" : "Finished" }

    func includes(isMarkedFinished: Bool) -> Bool {
        isMarkedFinished == (self == .finished)
    }

    @MainActor
    func groups(from groups: [ProjectGroup]) -> [ProjectGroup] {
        groups.compactMap { group in
            let sessions = group.sessions.filter { includes(isMarkedFinished: $0.isMarkedFinished) }
            guard !sessions.isEmpty || (self == .queue && (group.isFavorite || group.project == .none)) else { return nil }
            return ProjectGroup(project: group.project, sessions: sessions, isFavorite: group.isFavorite)
        }
    }
}

struct ProjectGroup: Identifiable {
    let project: Project
    let sessions: [AgentSession]
    let isFavorite: Bool

    var id: String { project.id }
}

/// A request to open the New Agent sheet, preset to a project.
struct Composer: Identifiable {
    let id = UUID()
    let project: Project
    var template: TaskTemplate?
}

@MainActor
final class SessionStore: ObservableObject {
    static let defaultPort: UInt16 = 47821
    private static let favoritesKey = "favoriteProjects"

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var favorites: [Project]
    @Published private(set) var serverError: String?
    @Published var agentList: AgentList = .queue
    @Published var selection: Selection? = .overview {
        didSet {
            if let selectedSession { agentList = selectedSession.isMarkedFinished ? .finished : .queue }
        }
    }
    @Published var composer: Composer?
    @Published var alert: String?

    let port: UInt16
    let notifications = AgentNotifications()
    let usage = UsageMonitor()
    let diagnostics = ProviderDiagnostics()
    let presets = TaskPresetStore()
    let skillLocations = SkillLocations()
    private var server: EventServer?
    private var database: SessionDatabase?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var unsaved: Set<UUID> = []
    private var expectedStops: Set<UUID> = []
    private var snapshotter: WindowSnapshotter?
    private var commandLineOptionsPending = true

    init() {
        port = ProcessInfo.processInfo.environment["AGENTICIOUS_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        favorites = (UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).map(Project.init(path:))
        openDatabase()
        startServer()
        snapshotter = LaunchOptions.current.snapshotDirectory.map(WindowSnapshotter.init)
    }

    // MARK: - Reading

    var composerProject: Project {
        if let selectedSession { return selectedSession.project }
        if let path = UserDefaults.standard.string(forKey: "lastWorkspace") {
            if path.isEmpty { return .none }
            if let favorite = favorites.first(where: { $0.path == path }) { return favorite }
        }
        return favorites.first ?? .none
    }

    var attentionCount: Int { sessions.filter { $0.status.needsAttention }.count }

    var visibleProjectGroups: [ProjectGroup] { agentList.groups(from: projectGroups) }
    var visibleSessions: [AgentSession] { sessions.filter { agentList.includes(isMarkedFinished: $0.isMarkedFinished) } }

    func count(in list: AgentList) -> Int { sessions.filter { list.includes(isMarkedFinished: $0.isMarkedFinished) }.count }

    func markFinished(_ session: AgentSession, finished: Bool) {
        guard !finished || session.canMarkFinished else { return }
        if finished { notifications.playSound("Pop") }
        session.isMarkedFinished = finished
        save(session)
        if finished { show(.queue) }
        else { selection = .session(session.id) }
    }

    func show(_ list: AgentList) {
        agentList = list
        selection = .overview
    }

    func session(_ id: UUID) -> AgentSession? { sessions.first { $0.id == id } }

    var selectedSession: AgentSession? {
        guard case let .session(id) = selection else { return nil }
        return session(id)
    }

    /// Favorites first (in the user's order, even when empty), then other folders that have agents, then "No project".
    var projectGroups: [ProjectGroup] {
        let others = Set(sessions.map(\.project)).subtracting(favorites + [.none]).sorted { $0.name < $1.name }

        return favorites.map { group($0, isFavorite: true) }
            + others.map { group($0, isFavorite: false) }
            + [group(.none, isFavorite: false)]
    }

    private func group(_ project: Project, isFavorite: Bool) -> ProjectGroup {
        let members = sessions
            .filter { $0.project == project }
            .sorted { ($0.status.sortRank, $1.startedAt) < ($1.status.sortRank, $0.startedAt) }
        return ProjectGroup(project: project, sessions: members, isFavorite: isFavorite)
    }

    // MARK: - Favorites

    func addFavorite(_ url: URL) -> Project {
        let project = Project(path: url.standardizedFileURL.path)
        if !favorites.contains(project) { favorites.append(project) }
        saveFavorites()
        return project
    }

    func removeFavorite(_ project: Project) {
        favorites.removeAll { $0 == project }
        saveFavorites()
    }

    private func saveFavorites() {
        UserDefaults.standard.set(favorites.compactMap(\.path), forKey: Self.favoritesKey)
    }

    // MARK: - Sessions

    @discardableResult
    func launch(
        task: String, prompt: String? = nil, agent: AgentKind, model: ModelChoice? = nil, effort: String? = nil, project: Project, isolated: Bool = false
    ) throws -> AgentSession {
        let worktree = try isolated ? project.path.map { try Worktrees.create(in: $0, for: task) } : nil
        let directory = try worktree.map { directory(inside: $0, for: project) } ?? directory(for: project)
        let session = AgentSession(
            task: task, prompt: prompt, agent: agent, project: project, directory: directory, worktree: worktree, model: model, effort: effort
        )
        if agent == .claude { session.conversationID = session.id.uuidString.lowercased() }
        let spec = try AgentLauncher(port: port).spec(for: session)

        attachTerminal(to: session, running: spec)
        sessions.insert(session, at: 0)
        track(session)
        save(session)
        selection = .session(session.id)

        return session
    }

    /// Starts the agent again on its earlier conversation, in the same folder, still reporting to this session.
    func resume(_ session: AgentSession) {
        guard session.canResume else {
            alert = "Can't resume: \(session.worktreeRemoved ? "its worktree was deleted" : "\(session.directory.path) no longer exists")."
            return
        }

        do {
            let spec = try AgentLauncher(port: port).spec(for: session, resuming: true)
            attachTerminal(to: session, running: spec)
            session.status = .yourTurn
            session.isMarkedFinished = false
            selection = .session(session.id)
        } catch {
            alert = "Couldn't resume the agent: \(error.localizedDescription)"
        }
    }

    /// The command-line options, handed out once so reopening the window doesn't launch the `--task` again.
    func takeCommandLineOptions() -> LaunchOptions? {
        guard commandLineOptionsPending else { return nil }

        commandLineOptionsPending = false
        return LaunchOptions.current
    }

    func stop(_ session: AgentSession) {
        if session.isRunning { expectedStops.insert(session.id) }
        session.terminalView?.terminate()
    }

    func remove(_ session: AgentSession) {
        stop(session)
        if selection == .session(session.id) { selection = .overview }
        subscriptions[session.id] = nil
        sessions.removeAll { $0.id == session.id }
        unsaved.remove(session.id)
        do {
            try database?.delete(session.id)
        } catch {
            alert = "Couldn't delete the agent from the database: \(error.localizedDescription)"
        }
        updateBadge()
    }

    /// Removes the agent's worktree folder (git refuses if it has uncommitted changes). The branch stays.
    func deleteWorktree(of session: AgentSession) {
        guard let worktree = session.worktree else { return }

        do {
            try Worktrees.remove(worktree)
            session.worktreeRemoved = true
        } catch {
            alert = "Couldn't delete the worktree: \(error.localizedDescription)"
        }
    }

    /// A project that is a subfolder of its repo keeps that subfolder inside the worktree.
    private func directory(inside worktree: Worktree, for project: Project) -> URL {
        let projectPath = URL(fileURLWithPath: project.path ?? worktree.repositoryRoot).resolvingSymlinksInPath().path
        let root = URL(fileURLWithPath: worktree.repositoryRoot).resolvingSymlinksInPath().path
        let relative = projectPath.hasPrefix(root) ? String(projectPath.dropFirst(root.count)) : ""
        return URL(fileURLWithPath: worktree.path + relative)
    }

    /// "No project" agents share one scratch folder, so Claude asks to trust it only once.
    private func directory(for project: Project) throws -> URL {
        if let path = project.path { return URL(fileURLWithPath: path) }

        let scratch = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func attachTerminal(to session: AgentSession, running spec: LaunchSpec) {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let bridge = TerminalBridge { [weak self, weak session] exitCode in
            guard let session else { return }
            let oldStatus = session.status
            session.isRunning = false
            if case .done = session.status {} else { session.status = .exited(exitCode) }
            if self?.expectedStops.remove(session.id) == nil {
                self?.notifyTransition(from: oldStatus, for: session)
            }
            self?.updateBadge()
        }

        terminal.processDelegate = bridge
        terminal.startProcess(executable: spec.executable, args: spec.arguments, environment: spec.environment, currentDirectory: spec.directory)

        session.terminalView = terminal
        session.terminalBridge = bridge
        session.isRunning = true
        notifications.playSound("Tink")
    }

    /// Re-publish every session change so lists re-sort when an agent flips to "needs you", and save it.
    private func track(_ session: AgentSession) {
        subscriptions[session.id] = session.objectWillChange.sink { [weak self, id = session.id] _ in
            self?.objectWillChange.send()
            self?.saveSoon(id)
        }
    }

    // MARK: - Database

    private func openDatabase() {
        do {
            let database = try SessionDatabase()
            sessions = try database.load()
            sessions.forEach(track)
            self.database = database
        } catch {
            alert = "Agents won't be saved: couldn't open the database (\(error.localizedDescription))."
        }
    }

    /// `objectWillChange` fires before the new value is stored, so save on the next turn of the run loop,
    /// once per session however many properties changed.
    private func saveSoon(_ id: UUID) {
        guard unsaved.insert(id).inserted else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self, unsaved.remove(id) != nil, let session = session(id) else { return }
            save(session)
        }
    }

    private func save(_ session: AgentSession) {
        do {
            try database?.save(session)
        } catch {
            alert = "Couldn't save the agent: \(error.localizedDescription)"
        }
    }

    // MARK: - Events

    private func startServer() {
        do {
            let server = try EventServer(port: port) { [weak self] event, reply in
                Task { @MainActor in reply(self?.handle(event)) }
            }
            server.start()
            self.server = server
        } catch {
            serverError = "Couldn't listen on port \(port): \(error.localizedDescription)"
        }
    }

    private func handle(_ event: AgentEvent) -> Data? {
        guard let session = session(event.sessionID) else { return nil }

        let payload = (try? JSONSerialization.jsonObject(with: event.body)) as? [String: Any] ?? [:]
        if event.name == "StatusLine" { return statusLine(payload) }

        session.lastActivity = Date()

        if event.name == "Stop", let reply = EventInterpreter.stopHookReply(payload, for: session) {
            session.status = .working
            return try? JSONSerialization.data(withJSONObject: reply)
        }

        let oldStatus = session.status
        EventInterpreter.apply(event.name, payload, to: session)
        notifyTransition(from: oldStatus, for: session)
        updateBadge()
        return nil
    }

    private func notifyTransition(from oldStatus: SessionStatus, for session: AgentSession) {
        guard let event = AgentAlert.transition(from: oldStatus, to: session.status) else { return }
        notifications.notify(event, sessionID: session.id, task: session.task)
    }

    /// Claude redraws its status line after every message, so this doubles as the feed for the toolbar's Claude limits.
    private func statusLine(_ payload: [String: Any]) -> Data {
        if let rateLimits = payload["rate_limits"] as? [String: Any] { usage.recordClaudeRateLimits(rateLimits) }

        let model = (payload["model"] as? [String: Any])?["display_name"] as? String
        let limits = (usage.claudeReading?.limits ?? []).map { "\($0.windowLabel) \(Int($0.currentPercent.rounded()))%" }
        return Data(([model].compactMap { $0 } + limits).joined(separator: " · ").utf8)
    }

    private func updateBadge() {
        NSApp.dockTile.badgeLabel = attentionCount > 0 ? String(attentionCount) : nil
    }
}

/// SwiftTerm's delegate for the child process; we only care about it exiting.
final class TerminalBridge: NSObject, LocalProcessTerminalViewDelegate {
    private let onExit: @MainActor (Int32?) -> Void

    init(onExit: @escaping @MainActor (Int32?) -> Void) {
        self.onExit = onExit
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in onExit(exitCode) }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
