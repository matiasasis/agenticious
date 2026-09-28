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
    /// Blocked on the human: a permission prompt, or the agent explicitly called `need_human`.
    case needsYou(String)
    /// The agent finished its turn and is idle, waiting for the next message. Nothing is blocked.
    case yourTurn
    case done(String?)
    case exited(Int32?)

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .yourTurn: "Your turn"
        case .done: "Done"
        case .exited: "Exited"
        }
    }

    var needsAttention: Bool {
        if case .needsYou = self { return true }
        return false
    }

    var isFinished: Bool {
        switch self {
        case .done, .exited: true
        default: false
        }
    }

    /// Lower sorts first: whatever is blocked on the human floats to the top.
    var sortRank: Int {
        switch self {
        case .needsYou: 0
        case .yourTurn: 1
        case .working, .starting: 2
        case .done: 3
        case .exited: 4
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
    let id = UUID()
    let task: String
    let agent: AgentKind
    let project: Project
    let directory: URL
    let startedAt = Date()
    /// Set when the agent runs in its own git worktree instead of the project checkout.
    let worktree: Worktree?

    @Published var status: SessionStatus = .starting
    @Published var chunks: [Chunk] = []
    @Published var lastActivity = Date()
    @Published var worktreeRemoved = false

    var planSource: PlanSource = .none
    var terminalView: LocalProcessTerminalView?
    var terminalBridge: TerminalBridge?

    init(task: String, agent: AgentKind, project: Project, directory: URL, worktree: Worktree? = nil) {
        self.task = task
        self.agent = agent
        self.project = project
        self.directory = directory
        self.worktree = worktree
    }

    var completedChunks: Int { chunks.filter { $0.status == .done }.count }

    var allChunksDone: Bool { !chunks.isEmpty && completedChunks == chunks.count }

    var hasExited: Bool {
        if case .exited = status { return true }
        return false
    }

    var hasOpenChunks: Bool { chunks.contains { $0.status != .done } }

    var currentChunk: Chunk? {
        chunks.first { $0.status == .inProgress || $0.status == .blocked } ?? chunks.first { $0.status == .pending }
    }
}
