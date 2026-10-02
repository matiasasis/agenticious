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
    private var backgroundRefresh: BackgroundRefresh?
    private var database: SessionDatabase?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var unsaved: Set<UUID> = []
    private var snapshotter: WindowSnapshotter?
    private var commandLineOptionsPending = true

    init(databaseURL: URL? = nil) {
        port = ProcessInfo.processInfo.environment["AGENTICIOUS_PORT"].flatMap(UInt16.init) ?? Self.defaultPort
        favorites = (UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? []).map(Project.init(path:))
        openDatabase(url: databaseURL)
        startServer()
        snapshotter = LaunchOptions.current.snapshotDirectory.map(WindowSnapshotter.init)
        notifications.perform = { [weak self] action, id, text in self?.perform(action, on: id, text: text) }
        let (usage, diagnostics) = (usage, diagnostics)
        backgroundRefresh = BackgroundRefresh(jobs: [
            .init(check: .providers, lastChecked: { diagnostics.lastChecked }, run: { Task { await diagnostics.refresh() } }),
            .init(check: .usage, lastChecked: { usage.lastChecked }, run: usage.refresh),
        ])
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

    var attentionCount: Int { sessions.filter { !$0.isMarkedFinished && $0.status.needsAttention }.count }

    var visibleProjectGroups: [ProjectGroup] { agentList.groups(from: projectGroups) }
    var visibleSessions: [AgentSession] { sessions.filter { agentList.includes(isMarkedFinished: $0.isMarkedFinished) } }

    func count(in list: AgentList) -> Int { sessions.filter { list.includes(isMarkedFinished: $0.isMarkedFinished) }.count }

    func markFinished(_ session: AgentSession, finished: Bool) {
        guard !session.isArchiving else { return }
        guard !finished || session.canMarkFinished else { return }
        if finished {
            archive(session)
            return
        }
        session.isMarkedFinished = false
        save(session)
        selection = .session(session.id)
    }

    func archive(_ session: AgentSession) {
        guard !session.isArchiving, session.backgroundTask == nil else { return }
        session.isArchiving = true
        session.releaseQuestion()
        session.backgroundTask = "Archiving…"
        let id = session.id
        let processID = session.terminalView?.process.running == true ? session.terminalView?.process.shellPid : nil
        let worktree = session.worktreeRemoved ? nil : session.worktree
        let sharedWorktree = worktree.map { tree in
            sessions.contains {
                $0.id != id && (!$0.isMarkedFinished || $0.isRunning)
                    && ($0.directory.path == tree.path || $0.directory.path.hasPrefix(tree.path + "/"))
            }
        } ?? false
        Task {
            let result = await Task.detached {
                SessionCleanup.run(id: id, processID: processID, worktree: worktree, sharedWorktree: sharedWorktree) { step in
                    Task { @MainActor in
                        if let session = self.session(id), session.isArchiving { session.backgroundTask = step }
                    }
                }
            }.value
            if result.processesStopped {
                if session.terminalView?.process.running == true { session.terminalView?.terminate() }
                session.terminalView?.removeFromSuperview()
                session.terminalView = nil
                session.terminalBridge = nil
                if session.isRunning || (!session.status.isFinished && session.status != .interrupted) { session.recordExit(nil) }
                session.worktreeRemoved = session.worktreeRemoved || result.worktreeRemoved
                session.isMarkedFinished = true
                notifications.playSound("Pop")
                if selection == .session(session.id) { show(.queue) }
            }
            session.isArchiving = false
            session.backgroundTask = nil
            save(session)
            updateBadge()
            if !result.warnings.isEmpty { alert = result.warnings.joined(separator: "\n\n") }
        }
    }

    func endChat(_ session: AgentSession) {
        guard session.canEndChat else { return }
        session.status = .ended("Chat ended by you.")
        save(session)
        archive(session)
    }

    func markEnded(_ session: AgentSession) {
        guard !session.isArchiving, !session.isMarkedFinished else { return }
        session.status = .ended("Work was stopped or handed off, as marked by you.")
        save(session)
        updateBadge()
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

    /// The card appears at once; creating the worktree and starting the CLI happen in the background, shown on the card.
    @discardableResult
    func launch(
        task: String, prompt: String? = nil, agent: AgentKind, model: ModelChoice? = nil, effort: String? = nil,
        project: Project, isolated: Bool = false, taskType: TaskType? = nil, images: [PastedImage] = []
    ) throws -> AgentSession {
        let id = UUID()
        let imageFiles = try PastedImage.save(images, into: AgentLauncher.sessionDirectory(for: id).appendingPathComponent("images"))
        let session = AgentSession(
            id: id, task: task, prompt: (prompt ?? task) + PastedImage.instructions(for: imageFiles), agent: agent,
            project: project, directory: URL(fileURLWithPath: project.path ?? NSHomeDirectory()),
            model: model, effort: effort, taskType: taskType
        )
        if agent == .claude { session.conversationID = session.id.uuidString.lowercased() }
        let worktreeIn = isolated && !session.isChat ? project.path : nil
        session.backgroundTask = worktreeIn == nil ? "Starting \(agent.displayName)…" : "Creating its worktree…"
        sessions.insert(session, at: 0)
        selection = .session(session.id)

        Task { await start(session, worktreeIn: worktreeIn, images: imageFiles) }
        return session
    }

    /// Saved and tracked only once running, so a launch that fails leaves nothing behind in the database.
    private func start(_ session: AgentSession, worktreeIn projectPath: String?, images: [URL]) async {
        do {
            if let projectPath {
                let task = session.task
                let worktree = try await Task.detached { try Worktrees.create(in: projectPath, for: task) }.value
                session.worktree = worktree
                session.directory = directory(inside: worktree, for: session.project)
                session.backgroundTask = "Starting \(session.agent.displayName)…"
            } else {
                session.directory = try directory(for: session.project)
            }
            attachTerminal(to: session, running: try AgentLauncher(port: port).spec(for: session, images: images))
            session.backgroundTask = nil
            track(session)
            save(session)
        } catch {
            sessions.removeAll { $0.id == session.id }
            if selection == .session(session.id) { selection = .overview }
            if let folder = try? AgentLauncher.sessionDirectory(for: session.id) { try? FileManager.default.removeItem(at: folder) }
            alert = "Couldn't start the agent: \(error.localizedDescription)"
        }
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
        guard session.isRunning, !session.isArchiving else { return }
        session.terminalView?.terminate()
        // SwiftTerm cancels its exit monitor when explicitly terminated.
        session.recordExit(nil)
        save(session)
        updateBadge()
    }

    func remove(_ session: AgentSession) {
        guard !session.isArchiving else { return }
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
        guard !session.isArchiving else { return }
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
        let bridge = TerminalBridge { [weak self, weak session, weak terminal] exitCode in
            guard let session, !session.isArchiving, session.isRunning, session.terminalView === terminal else { return }
            let oldStatus = session.status
            session.recordExit(exitCode)
            self?.notifyTransition(from: oldStatus, for: session)
            self?.updateBadge()
        }

        terminal.processDelegate = bridge
        terminal.startProcess(executable: spec.executable, args: spec.arguments, environment: spec.environment, currentDirectory: spec.directory)

        session.terminalView = terminal
        session.terminalBridge = bridge
        session.isRunning = true
        if terminal.process.running { notifications.playSummonSound() }
        Task { await monitorStartup(of: session, terminal: terminal) }
    }

    private func monitorStartup(of session: AgentSession, terminal: LocalProcessTerminalView) async {
        var cached: URL?
        var stamp: TranscriptStamp?
        var previousID = session.conversationID
        while session.isRunning, session.chunks.isEmpty, !session.status.isFinished,
              session.terminalView === terminal, self.session(session.id) != nil {
            updateStartupPrompt(of: session, terminal: terminal)
            let agent = session.agent
            let id = session.id
            let conversation = session.conversationID
            let directory = session.directory.path
            if previousID != conversation { cached = nil; stamp = nil; previousID = conversation }
            let file = cached
            let lastStamp = stamp
            let result = await Task.detached(priority: .utility) {
                ActivityTranscript.read(agent: agent, sessionID: id, conversationID: conversation,
                                        directory: directory, cached: file, stamp: lastStamp)
            }.value
            guard session.isRunning, session.chunks.isEmpty, !session.isArchiving,
                  session.terminalView === terminal else { return }
            if session.conversationID != conversation { continue }
            cached = result.url
            stamp = result.stamp
            if !result.isUnchanged {
                session.startupProgress.update(from: result)
                if session.status == .starting, !result.entries.isEmpty { session.status = .working }
            }
            if session.conversationID == nil, let conversation = result.conversationID {
                session.conversationID = conversation
                previousID = conversation
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func updateStartupPrompt(of session: AgentSession, terminal: LocalProcessTerminalView) {
        guard session.status == .starting || session.startupPrompt != nil else { return }
        let oldStatus = session.status
        let prompt = StartupPrompt.detect(in: terminal.getTerminal(), agent: session.agent)
        StartupPromptInterpreter.apply(prompt, to: session)
        guard session.status != oldStatus else { return }
        notifyTransition(from: oldStatus, for: session)
        updateBadge()
    }

    /// Re-publish every session change so lists re-sort when an agent flips to "needs you", and save it.
    private func track(_ session: AgentSession) {
        subscriptions[session.id] = session.objectWillChange.sink { [weak self, id = session.id] _ in
            self?.objectWillChange.send()
            self?.saveSoon(id)
        }
    }

    // MARK: - Database

    private func openDatabase(url: URL?) {
        do {
            let database = try SessionDatabase(url: url)
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
                Task { @MainActor in
                    guard let self else { return reply(nil) }
                    if event.name == "AskUserQuestion" { self.hold(event, reply: reply) } else { reply(self.handle(event)) }
                }
            }
            server.start()
            self.server = server
        } catch {
            serverError = "Couldn't listen on port \(port): \(error.localizedDescription)"
        }
    }

    private func handle(_ event: AgentEvent) -> Data? {
        guard let session = session(event.sessionID), !session.isArchiving, !session.isMarkedFinished else { return nil }

        let payload = (try? JSONSerialization.jsonObject(with: event.body)) as? [String: Any] ?? [:]
        if event.name == "StatusLine" { return statusLine(payload) }

        session.lastActivity = Date()

        if Self.movesPastQuestion(event.name, payload) { session.releaseQuestion() }

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
        notifications.notify(event, sessionID: session.id, message: event.message(task: session.task))
    }

    private func perform(_ action: AgentNotificationAction, on id: UUID, text: String?) {
        guard let session = session(id), !session.isMarkedFinished else { return }
        switch action {
        case .open: notifications.requestedSession = id
        case .reply: reply(text ?? "", to: session)
        case .resume: resume(session)
        case .archive: archive(session)
        }
    }

    // MARK: - Questions

    /// Keeps Claude's AskUserQuestion hook waiting while the question shows in Activity. Subagents, and agents
    /// Agenticious isn't showing, get no reply, so Claude's own menu appears.
    private func hold(_ event: AgentEvent, reply: @escaping (Data?) -> Void) {
        let payload = (try? JSONSerialization.jsonObject(with: event.body)) as? [String: Any] ?? [:]
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let questions = AgentQuestion.parse(input)
        guard let session = session(event.sessionID), session.isRunning, !session.isArchiving,
              payload["agent_id"] == nil, let first = questions.first else { return reply(nil) }

        session.releaseQuestion()
        session.lastActivity = Date()
        session.pendingQuestion = PendingQuestion(toolUseID: payload["tool_use_id"] as? String ?? "", questions: questions,
                                                  input: input, respond: reply)
        let oldStatus = session.status
        session.isAwaitingPermission = false
        session.status = .needsYou(first.text)
        notifyTransition(from: oldStatus, for: session)
        updateBadge()
    }

    /// Sends the answers through the held hook; Claude continues as if they were picked in its menu.
    func answer(_ session: AgentSession, with answers: [String: String]) {
        guard let question = session.pendingQuestion else { return }
        session.pendingQuestion = nil
        question.respond(PendingQuestion.hookReply(input: question.input, answers: answers))
        session.status = .working
        updateBadge()
    }

    /// Any later step of the main agent means the held question was answered or abandoned elsewhere.
    private static func movesPastQuestion(_ event: String, _ payload: [String: Any]) -> Bool {
        guard payload["agent_id"] == nil else { return false }
        switch event {
        case "PreToolUse": return payload["tool_name"] as? String != "AskUserQuestion"
        case "PostToolUse", "Stop", "UserPromptSubmit": return true
        default: return false
        }
    }

    /// Types the message into the agent's terminal and submits it. Only while the agent sits idle at its prompt:
    /// a permission menu or a running turn could take the keystrokes as something else, so then it opens instead.
    func reply(_ text: String, to session: AgentSession) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, session.canReplyInline, let terminal = session.terminalView else {
            notifications.requestedSession = session.id
            return
        }
        terminal.send(txt: text)
        if session.isChat { session.status = .working }
        // Sent on its own, so the CLI reads Enter rather than a newline inside pasted text.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { terminal.send(txt: "\r") }
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
