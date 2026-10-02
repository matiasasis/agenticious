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
    /// Blocked on the human: a permission prompt, or the agent explicitly called `need_human`.
    case needsYou(String)
    /// The agent finished its turn and is idle, waiting for the next message. Nothing is blocked.
    case yourTurn
    case done(String?)
    case ended(String)
    case exited(Int32?)
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
        case .yourTurn: "Your turn"
        case .done: "Done"
        case .ended: "Ended"
        case .exited: "Exited"
        case .paused: "Paused"
        case .interrupted: "Interrupted"
        }
    }

    var needsAttention: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var isFinished: Bool {
        switch self {
        case .done, .ended, .exited: true
        default: false
        }
    }

    /// Lower sorts first: whatever is blocked on the human floats to the top.
    var sortRank: Int {
        switch self {
        case .needsYou: 0
        case .yourTurn: 1
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
        }
    }
    @Published var startupProgress = StartupProgress()
    @Published var startupPrompt: StartupPrompt?
    @Published var chunks: [Chunk] = []
    @Published private(set) var pullRequests: [PullRequestReference] = []
    @Published var lastActivity = Date()
    @Published var worktreeRemoved = false
    @Published var isRunning = false

    var planSource: PlanSource = .none
    /// Needs you because of a permission prompt, which a subagent can be the one waiting on.
    var isAwaitingPermission = false
    /// A question Claude asked with AskUserQuestion, waiting for an answer in Activity.
    @Published var pendingQuestion: PendingQuestion?
    /// The CLI's own session id (Claude's session id, Codex's thread id), which is what `--resume` takes.
    var conversationID: String?
    var terminalView: LocalProcessTerminalView?
    var terminalBridge: TerminalBridge?

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

    func recordExit(_ code: Int32?) {
        releaseQuestion()
        isRunning = false
        switch status {
        case .done, .ended: break
        default: status = .exited(code)
        }
    }

    /// Hands a held question back to Claude without answers: its own menu appears in the terminal, or, once the
    /// agent has moved on, the stale hook simply ends.
    func releaseQuestion() {
        pendingQuestion?.respond(nil)
        pendingQuestion = nil
    }

    /// Typing a reply is safe while the agent waits at its prompt: after its turn, or after asking via need_human.
    /// Permission menus, startup prompts and held questions take keystrokes as choices, so they're answered elsewhere.
    var canReplyInline: Bool {
        guard isRunning, terminalView != nil, pendingQuestion == nil, startupPrompt == nil else { return false }
        return status == .yourTurn || (status.needsAttention && !isAwaitingPermission)
    }

    var completedChunks: Int { chunks.filter { $0.status == .done }.count }

    var isWorking: Bool { status == .starting || (status == .working && isRunning) }

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
        releaseQuestion()
        startupProgress = StartupProgress()
    }

    var hasOpenChunks: Bool { chunks.contains { $0.status != .done } }

    var currentChunk: Chunk? {
        chunks.first { $0.status == .inProgress || $0.status == .blocked } ?? chunks.first { $0.status == .pending }
    }
}
