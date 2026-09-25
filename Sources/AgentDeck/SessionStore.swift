import AppKit
import Combine
import SwiftTerm

enum Selection: Hashable {
    case overview
    case session(UUID)
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
}

@MainActor
final class SessionStore: ObservableObject {
    static let defaultPort: UInt16 = 47821
    private static let favoritesKey = "favoriteProjects"

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var favorites: [Project]
    @Published private(set) var serverError: String?
    @Published var selection: Selection? = .overview
    @Published var composer: Composer?

    let port: UInt16
    private var server: EventServer?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var snapshotter: WindowSnapshotter?
    private var commandLineTaskPending = true

    init() {
        port = ProcessInfo.processInfo.environment["AGENTDECK_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        favorites = (UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).map(Project.init(path:))
        startServer()
        snapshotter = LaunchOptions.current.snapshotDirectory.map(WindowSnapshotter.init)
    }

    // MARK: - Reading

    var attentionCount: Int { sessions.filter { $0.status.needsAttention }.count }

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
    func launch(task: String, agent: AgentKind, project: Project) throws -> AgentSession {
        let session = AgentSession(task: task, agent: agent, project: project, directory: try directory(for: project))
        let spec = try AgentLauncher(port: port).spec(for: session)

        attachTerminal(to: session, running: spec)
        track(session)
        selection = .session(session.id)

        return session
    }

    /// The `--task` from the command line, handed out once so reopening the window doesn't relaunch it.
    func takeCommandLineTask() -> String? {
        guard commandLineTaskPending else { return nil }

        commandLineTaskPending = false
        return LaunchOptions.current.task
    }

    func stop(_ session: AgentSession) {
        session.terminalView?.terminate()
    }

    func remove(_ session: AgentSession) {
        stop(session)
        if selection == .session(session.id) { selection = .overview }
        subscriptions[session.id] = nil
        sessions.removeAll { $0.id == session.id }
        updateBadge()
    }

    /// "No project" agents share one scratch folder, so Claude asks to trust it only once.
    private func directory(for project: Project) throws -> URL {
        if let path = project.path { return URL(fileURLWithPath: path) }

        let scratch = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck/scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return scratch
    }

    private func attachTerminal(to session: AgentSession, running spec: LaunchSpec) {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let bridge = TerminalBridge { [weak self, weak session] exitCode in
            guard let session else { return }
            if case .done = session.status {} else { session.status = .exited(exitCode) }
            self?.updateBadge()
        }

        terminal.processDelegate = bridge
        terminal.startProcess(executable: spec.executable, args: spec.arguments, environment: spec.environment, currentDirectory: spec.directory)

        session.terminalView = terminal
        session.terminalBridge = bridge
    }

    /// Re-publish every session change so lists re-sort when an agent flips to "needs you".
    private func track(_ session: AgentSession) {
        subscriptions[session.id] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        sessions.insert(session, at: 0)
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
        session.lastActivity = Date()

        if event.name == "Stop", let reply = EventInterpreter.stopHookReply(payload, for: session) {
            return try? JSONSerialization.data(withJSONObject: reply)
        }

        let neededAttention = session.status.needsAttention
        EventInterpreter.apply(event.name, payload, to: session)
        if !neededAttention && session.status.needsAttention { NSSound(named: "Glass")?.play() }
        updateBadge()
        return nil
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
