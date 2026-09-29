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
        case .interrupted: 3
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
    let directory: URL
    let startedAt: Date
    /// Set when the agent runs in its own git worktree instead of the project checkout.
    let worktree: Worktree?
    /// Nil leaves the CLI's own default in place.
    let model: ModelChoice?
    let effort: String?
    let taskType: TaskType?

    @Published var isMarkedFinished = false
    @Published var isArchiving = false
    @Published var status: SessionStatus = .starting
    @Published var chunks: [Chunk] = []
    @Published private(set) var pullRequests: [PullRequestReference] = []
    @Published var lastActivity = Date()
    @Published var worktreeRemoved = false
    @Published var isRunning = false

    var planSource: PlanSource = .none
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

    var canMarkFinished: Bool {
        guard !isMarkedFinished, !isArchiving else { return false }
        if case .done = status { return true }
        return false
    }

    func recordExit(_ code: Int32?) {
        isRunning = false
        switch status {
        case .done, .ended: break
        default: status = .exited(code)
        }
    }

    var completedChunks: Int { chunks.filter { $0.status == .done }.count }

    var allChunksDone: Bool { !chunks.isEmpty && completedChunks == chunks.count }

    /// Resuming reopens the conversation in the folder it ran in, so a deleted worktree can't come back.
    var canResume: Bool {
        !isRunning && !isArchiving && !worktreeRemoved && FileManager.default.fileExists(atPath: directory.path)
    }

    var hasOpenChunks: Bool { chunks.contains { $0.status != .done } }

    var currentChunk: Chunk? {
        chunks.first { $0.status == .inProgress || $0.status == .blocked } ?? chunks.first { $0.status == .pending }
    }
}
