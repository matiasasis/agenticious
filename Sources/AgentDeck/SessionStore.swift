import AppKit
import Combine
import SwiftTerm

@MainActor
final class SessionStore: ObservableObject {
    static let defaultPort: UInt16 = 47821

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var serverError: String?

    let port: UInt16
    private var server: EventServer?
    private var subscriptions: [UUID: AnyCancellable] = [:]

    init() {
        port = ProcessInfo.processInfo.environment["AGENTDECK_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        startServer()
    }

    var sortedSessions: [AgentSession] {
        sessions.sorted { ($0.status.sortRank, $1.startedAt) < ($1.status.sortRank, $0.startedAt) }
    }

    var attentionCount: Int { sessions.filter { $0.status.needsAttention }.count }

    func session(_ id: UUID) -> AgentSession? { sessions.first { $0.id == id } }

    @discardableResult
    func launch(task: String, agent: AgentKind, directory: URL) throws -> AgentSession {
        let session = AgentSession(task: task, agent: agent, directory: directory)
        let spec = try AgentLauncher(port: port).spec(for: session)

        attachTerminal(to: session, running: spec)
        track(session)

        return session
    }

    func stop(_ session: AgentSession) {
        session.terminalView?.terminate()
    }

    func remove(_ session: AgentSession) {
        stop(session)
        subscriptions[session.id] = nil
        sessions.removeAll { $0.id == session.id }
        updateBadge()
    }

    // MARK: - Launching

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

    /// Re-publish every session change so the dashboard re-sorts when a card flips to "needs you".
    private func track(_ session: AgentSession) {
        subscriptions[session.id] = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        sessions.insert(session, at: 0)
    }

    // MARK: - Events

    private func startServer() {
        do {
            let server = try EventServer(port: port) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            server.start()
            self.server = server
        } catch {
            serverError = "Couldn't listen on port \(port): \(error.localizedDescription)"
        }
    }

    private func handle(_ event: AgentEvent) {
        guard let session = session(event.sessionID) else { return }

        let payload = (try? JSONSerialization.jsonObject(with: event.body)) as? [String: Any] ?? [:]
        let neededAttention = session.status.needsAttention

        EventInterpreter.apply(event.name, payload, to: session)
        session.lastActivity = Date()

        if !neededAttention && session.status.needsAttention { NSSound(named: "Glass")?.play() }
        updateBadge()
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
