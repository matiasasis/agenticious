import Foundation
import SwiftTerm

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// What the login shell runs.
    var command: String { rawValue }

    var npmPackage: String { self == .claude ? "@anthropic-ai/claude-code" : "@openai/codex" }
}

/// A folder agents work in, or `none` for questions that don't belong to any codebase.
struct Project: Identifiable, Hashable {
    let path: String?

    static let none = Project(path: nil)

    var id: String { path ?? "∅" }

    var name: String { path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project" }

    var symbol: String { path == nil ? "lightbulb" : "folder" }
}

enum SessionStatus: Equatable {
    case starting
    case working
    case waiting
    /// Blocked on the human: a question, a prompt only the terminal can show, or the agent called `need_human`.
    case needsYou(String)
    /// Claude asked to use a tool. While its card is held in Activity only `AgentSession.presentedStatus` produces this;
    /// it is stored when the terminal is the only place left to answer.
    case permissionRequired(String)
    /// The agent finished its turn and is idle, waiting for the next message. Nothing is blocked.
    case yourTurn
    case done(String?)
    case ended(String)
    case exited(Int32?)
    /// The process ended before anything showed the CLI running, so there is no conversation to resume.
    case notStarted(LaunchFailure)
    /// The human paused the agent. Its conversation and worktree stay, so Resume continues it.
    case paused
    /// Agenticious quit while the agent was still going. Resuming reopens its conversation.
    case interrupted

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .waiting: "Waiting"
        case .needsYou: "Needs you"
        case .permissionRequired: "Permission required"
        case .yourTurn: "Your turn"
        case .done: "Done"
        case .ended: "Ended"
        case .exited: "Exited"
        case .notStarted: "Didn't start"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        }
    }

    var needsAttention: Bool { attention != nil }

    /// What a blocked agent waits for, for every place that spells it out.
    var attention: (title: String, reason: String, symbol: String)? {
        switch self {
        case let .needsYou(reason): ("Needs you", reason, "hand.raised.fill")
        case let .permissionRequired(request): ("Permission required", request, "lock.shield.fill")
        default: nil
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .ended, .exited, .notStarted: true
        default: false
        }
    }

    var launchFailure: LaunchFailure? {
        if case let .notStarted(failure) = self { failure } else { nil }
    }

    /// Lower sorts first: whatever is blocked on the human floats to the top.
    var sortRank: Int {
        switch self {
        case .needsYou, .permissionRequired: 0
        case .yourTurn, .notStarted: 1
        case .working, .starting, .waiting: 2
        case .paused, .interrupted: 3
        case .done: 4
        case .ended: 5
        case .exited: 5
        }
    }
}

enum ChunkStatus: String {
    case pending
    case inProgress = "in_progress"
    case done
    case blocked
}

struct Chunk: Identifiable, Equatable {
    let id: Int
    var title: String
    var status: ChunkStatus
    var note: String?
}

enum PlanSource {
    case none
    case todoList   // mirrored from Claude's own TodoWrite tool
    case agent      // declared explicitly through the agenticious MCP tools; wins over todoList
}

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let task: String
    /// What the agent is told. Usually the task itself; a template sends full instructions under a short title.
    let prompt: String
    let agent: AgentKind
    let project: Project
    /// Where the agent runs. Settles once its worktree exists, which happens in the background after launch.
    @Published var directory: URL
    let startedAt: Date
    /// Set when the agent runs in its own git worktree instead of the project checkout.
    @Published var worktree: Worktree?
    /// Nil leaves the CLI's own default in place.
    let model: ModelChoice?
    let effort: String?
    let taskType: TaskType?

    @Published var isMarkedFinished = false
    @Published var isArchiving = false
    /// What the app is doing for this agent in the background, like starting or archiving it. Cards gray out and show it.
    @Published var backgroundTask: String?
    @Published var status: SessionStatus = .starting {
        didSet {
            if let startupPrompt, status != .needsYou(startupPrompt.reason) { self.startupPrompt = nil }
            if case .ended = status { releasePermissions() }
        }
    }
    @Published var startupProgress = StartupProgress()
    @Published var startupPrompt: StartupPrompt?
    @Published var chunks: [Chunk] = []
    @Published private(set) var pullRequests: [PullRequestReference] = []
    @Published var lastActivity = Date()
    @Published var worktreeRemoved = false
    @Published var isRunning = false
    /// Claude subagents this agent started, oldest first. Hooks keep them live; earlier runs come from Claude's logs.
    @Published var subagents: [Subagent] = []
    /// Commands the agent registered to undo what it made outside its worktree. Ones that ran cleanly are dropped.
    @Published var cleanupTasks: [CleanupTask] = []

    var planSource: PlanSource = .none
    /// A permission menu is waiting in the terminal, and only there. A subagent can be the one waiting on it.
    var isAwaitingPermission = false
    /// What `status` became when a request of the main agent's went to the terminal. While `status` is still that,
    /// the main agent's next Stop or prompt proves its menu gone. Any other writer of `status` voids it by not matching.
    var mainAgentTerminalWait: SessionStatus?
    /// The same for a subagent's request. Its menu outlives the main agent's turn, so the main agent's next Stop or
    /// prompt settles it only once no handed-over menu is left.
    var subagentTerminalWait: SessionStatus?
    /// Subagents' requests handed to Claude's own menu and not yet seen answered. Only that subagent's own hooks
    /// clear one: the main agent's tool events and turn ends say nothing about another agent's menu.
    private(set) var terminalMenus: [PermissionRequest] = []
    /// A reply typed and not sent. A permission or question card takes the reply box away, and must not take the words.
    var replyDraft = ""
    /// A question Claude asked with AskUserQuestion, waiting for an answer in Activity.
    @Published var pendingQuestion: PendingQuestion?
    /// Permission requests held open by Claude's PermissionRequest hook, oldest first. Never saved: a held hook dies with the app.
    @Published private(set) var pendingPermissions: [PendingPermission] = []
    /// Calls whose PreToolUse arrived and whose result has not: ties a request, which has no tool_use_id, to its PostToolUse.
    private(set) var openToolCalls: [OpenToolCall] = []
    /// The CLI's own session id (Claude's session id, Codex's thread id), which is what `--resume` takes.
    var conversationID: String?
    /// Claude's log of this conversation, from its hooks. Subagent logs sit next to it.
    var transcriptURL: URL?
    var terminalView: AgentTerminalView?
    var terminalBridge: TerminalBridge?
    /// Something showed the CLI running since this launch: a hook, a CLI screen, or its transcript moving.
    var cliConfirmed = false
    /// What a start-up prompt took attention from, given back when it clears.
    var statusBeforeStartupPrompt: SessionStatus?

    init(
        id: UUID = UUID(), task: String, prompt: String? = nil, agent: AgentKind, project: Project, directory: URL,
        startedAt: Date = Date(), worktree: Worktree? = nil, model: ModelChoice? = nil, effort: String? = nil, taskType: TaskType? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.task = task
        self.prompt = prompt ?? task
        self.agent = agent
        self.project = project
        self.directory = directory
        self.worktree = worktree
        self.model = model
        self.effort = effort
        self.taskType = taskType
        recordPullRequests(in: task + "\n" + self.prompt)
    }

    /// "Opus · High", or nil when both are left at the CLI default.
    var modelSummary: String? {
        let parts = [model?.name, effort.map(ModelCatalog.effortName)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func recordPullRequests(in text: String) {
        let additions = PullRequestReference.extract(from: text).filter { !pullRequests.contains($0) }
        for reference in additions where !pullRequests.contains(reference) { pullRequests.append(reference) }
    }

    var displayedTaskType: TaskType { taskType ?? TaskType.legacy(title: task) }
    var isChat: Bool { displayedTaskType.isChat }
    var canEndChat: Bool { isChat && !isMarkedFinished && !isArchiving && backgroundTask == nil }

    var canMarkFinished: Bool {
        guard !isMarkedFinished, !isArchiving else { return false }
        if case .done = status { return true }
        return false
    }

    func recordExit(_ code: Int32?, launchFailure: LaunchFailure? = nil) {
        releaseHeldRequests()
        // The terminal's menus went with the process. Archiving releases too, but its process runs on for a while.
        terminalMenus = []
        isRunning = false
        stopSubagents()
        switch status {
        case .done, .ended: break
        default: status = launchFailure.map(SessionStatus.notStarted) ?? .exited(code)
        }
    }

    /// A launch that failed rather than ended: it exited unsuccessfully before anything showed the CLI running.
    func launchFailure(exitCode: Int32?, output: [String], resuming: Bool) -> LaunchFailure? {
        guard !cliConfirmed, exitCode != 0 else { return nil }
        return LaunchFailure(code: exitCode, output: output, resuming: resuming)
    }

    /// One line for the sidebar and the banner: the likely cause, else the shell's last words.
    var launchFailureSummary: String? {
        guard let failure = status.launchFailure else { return nil }
        if let cause = failure.diagnosis(for: agent)?.cause { return cause }
        if let last = failure.output.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { return TerminalScreen.oneLine(last) }
        return "\(agent.displayName) ended before it started (\(failure.codeDescription))."
    }

    /// Hands a held question back to Claude without answers: its own menu appears in the terminal, or, once the
    /// agent has moved on, the stale hook simply ends.
    func releaseQuestion() {
        pendingQuestion?.respond(nil)
        pendingQuestion = nil
    }

    // MARK: - Permission requests

    /// What every list, pill, banner, counter and alert shows. `status` stays what the hooks last said, so it is
    /// right again the moment the last request is answered.
    var presentedStatus: SessionStatus {
        guard isRunning, !isMarkedFinished, let front = pendingPermissions.first else { return status }
        if case .ended = status { return status }
        return .permissionRequired(front.request.statusReason(waiting: pendingPermissions.count - 1))
    }

    func hold(_ pending: PendingPermission) { pendingPermissions.append(pending) }

    /// Removes the request and hands it to the caller, who alone replies. Nil for one already answered or released.
    func takePermission(_ id: UUID) -> PendingPermission? {
        guard let index = pendingPermissions.firstIndex(where: { $0.id == id }) else { return nil }
        let taken = pendingPermissions.remove(at: index)
        closeToolCalls(of: [taken.request])
        return taken
    }

    /// Hands held requests back to Claude's own menu with an empty reply, which is never a decision.
    @discardableResult
    func releasePermissions(where matches: (PermissionRequest) -> Bool = { _ in true }) -> [PermissionRequest] {
        let released = pendingPermissions.filter { matches($0.request) }
        guard !released.isEmpty else { return [] }
        pendingPermissions.removeAll { matches($0.request) }
        closeToolCalls(of: released.map(\.request))
        released.forEach { $0.respond(nil) }
        return released.map(\.request)
    }

    /// A request that left the queue no longer needs its call. Left open, a call that never reports back (denied,
    /// or interrupted) would lend its id to the next identical request, which its PostToolUse could then not release.
    private func closeToolCalls(of requests: [PermissionRequest]) {
        let ids = Set(requests.compactMap(\.toolUseID))
        if !ids.isEmpty { openToolCalls.removeAll { ids.contains($0.toolUseID) } }
    }

    func trackToolCall(_ event: String, _ payload: [String: Any]) {
        guard let id = payload["tool_use_id"] as? String else { return }
        switch event {
        case "PreToolUse":
            openToolCalls.append(OpenToolCall(toolUseID: id, fingerprint: PermissionRequest.fingerprint(of: payload),
                                              isFromSubagent: PermissionRequest.agentID(in: payload) != nil))
            if openToolCalls.count > 64 { openToolCalls.removeFirst(openToolCalls.count - 64) }
        case "PostToolUse", "PostToolUseFailure":
            openToolCalls.removeAll { $0.toolUseID == id }
        default: break
        }
    }

    func forgetMainToolCalls() { openToolCalls.removeAll { !$0.isFromSubagent } }

    /// The newest running call with this fingerprint that no held request has claimed yet. An agent asks about a
    /// call right after its PreToolUse; an older identical call still open was answered unseen and never reported.
    func toolUseID(matching fingerprint: String) -> String? {
        let claimed = Set(pendingPermissions.compactMap(\.request.toolUseID))
        return openToolCalls.last { $0.fingerprint == fingerprint && !claimed.contains($0.toolUseID) }?.toolUseID
    }

    func awaitTerminalMenu(for request: PermissionRequest) {
        if request.isFromSubagent { terminalMenus.append(request) }
    }

    /// A subagent got past a menu it was handed only when it stops, or when the call it asked about finishes or
    /// fails. Its other calls prove nothing: read-only calls of one message run side by side, so another may start
    /// or finish with the menu still up.
    func settleTerminalMenus(_ event: String, _ payload: [String: Any]) {
        guard !terminalMenus.isEmpty, PermissionRequest.agentID(in: payload) != nil else { return }
        let answered = PermissionRequest.ended(by: event, payload, among: terminalMenus)
        terminalMenus.removeAll { answered.contains($0.id) }
    }

    /// Where a handed-over menu's call would have its result written: its subagent's own log. Nil when either is
    /// unknown, which keeps the menu listed.
    var terminalMenuResults: [(menu: UUID, toolUseID: String, transcript: URL)] {
        terminalMenus.compactMap { menu in
            guard let id = menu.toolUseID, let agent = menu.agentID,
                  let url = subagents.first(where: { $0.id == agent })?.transcript
                      ?? transcriptURL.map({ SubagentCatalog.transcript(of: agent, conversation: $0) }) else { return nil }
            return (menu.id, id, url)
        }
    }

    /// Claude wrote these calls' results, so their menus closed, however: a subagent stopped mid-run sends no hook.
    func dropTerminalMenus(_ ids: Set<UUID>) {
        guard terminalMenus.contains(where: { ids.contains($0.id) }) else { return }
        // Not published itself, and nothing else changes with it: the reply box has to hear of it.
        objectWillChange.send()
        terminalMenus.removeAll { ids.contains($0.id) }
    }

    /// Question and permission requests alike go back to Claude's own menus.
    @discardableResult
    func releaseHeldRequests() -> [PermissionRequest] {
        releaseQuestion()
        let released = releasePermissions()
        openToolCalls = []
        return released
    }

    /// Typing a reply is safe while the agent waits at its prompt: after its turn, or after asking via need_human.
    /// Permission menus, startup prompts and held questions take keystrokes as choices, so they're answered elsewhere.
    var canReplyInline: Bool {
        guard isRunning, terminalView != nil, pendingQuestion == nil, pendingPermissions.isEmpty, terminalMenus.isEmpty,
              startupPrompt == nil else { return false }
        return statusOpensReplyBox
    }

    /// What the hooks last said would, on its own, let a reply be typed into the terminal.
    var statusOpensReplyBox: Bool {
        if case .permissionRequired = status { return false }
        return status == .yourTurn || (status.needsAttention && !isAwaitingPermission)
    }

    var completedChunks: Int { chunks.filter { $0.status == .done }.count }

    var isWorking: Bool {
        let status = presentedStatus
        return status == .starting || (status == .working && isRunning)
    }

    var startupSteps: [Chunk] {
        guard !isChat, chunks.isEmpty, backgroundTask == nil, !isArchiving, !isMarkedFinished,
              status == .starting || (status == .working && isRunning) else { return [] }
        return startupProgress.steps(for: agent, submitted: status == .working)
    }

    var allChunksDone: Bool { !chunks.isEmpty && completedChunks == chunks.count }

    /// A finished agent's process only idles; Archive stops it along with the cleanup.
    var canStop: Bool { isRunning && !status.isFinished }

    /// Done or ended work only needs Archive.
    var canEnd: Bool {
        guard !isChat, !isMarkedFinished, !isArchiving, backgroundTask == nil else { return false }
        switch status {
        case .done, .ended: return false
        default: return true
        }
    }

    var showsResumeAction: Bool {
        if case .done = status { return false }
        return !isRunning
    }

    /// Resuming reopens the conversation in the folder it ran in, so a deleted worktree can't come back.
    var canResume: Bool {
        showsResumeAction && !isArchiving && backgroundTask == nil && !worktreeRemoved && FileManager.default.fileExists(atPath: directory.path)
    }

    var resumePrompt: String? {
        guard !isChat, conversationID != nil else { return nil }
        if case .done = status { return nil }
        return "Continue the unfinished task from where you left off. Review the conversation and current progress, then proceed with the remaining work."
    }

    func prepareToResume() {
        status = resumePrompt == nil ? .yourTurn : .starting
        isMarkedFinished = false
        isAwaitingPermission = false
        releaseHeldRequests()
        terminalMenus = []
        startupProgress = StartupProgress()
    }

    var hasOpenChunks: Bool { chunks.contains { $0.status != .done } }

    var currentChunk: Chunk? {
        chunks.first { $0.status == .inProgress || $0.status == .blocked } ?? chunks.first { $0.status == .pending }
    }
}
