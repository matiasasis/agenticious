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

enum SessionStatus: Equatable {
    case starting
    case working
    case needsYou(String)
    case done(String?)
    case exited(Int32?)

    var label: String {
        switch self {
        case .starting: "Starting"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .exited: "Exited"
        }
    }

    var needsAttention: Bool {
        if case .needsYou = self { return true }
        return false
    }

    /// Lower sorts first on the dashboard: whatever is blocked on the human floats to the top.
    var sortRank: Int {
        switch self {
        case .needsYou: 0
        case .working, .starting: 1
        case .done: 2
        case .exited: 3
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
    case agent      // declared explicitly through the agentdeck MCP tools; wins over todoList
}

@MainActor
final class AgentSession: ObservableObject, Identifiable {
    let id = UUID()
    let task: String
    let agent: AgentKind
    let directory: URL
    let startedAt = Date()

    @Published var status: SessionStatus = .starting
    @Published var chunks: [Chunk] = []
    @Published var lastActivity = Date()

    var planSource: PlanSource = .none
    var terminalView: LocalProcessTerminalView?
    var terminalBridge: TerminalBridge?

    init(task: String, agent: AgentKind, directory: URL) {
        self.task = task
        self.agent = agent
        self.directory = directory
    }

    var completedChunks: Int { chunks.filter { $0.status == .done }.count }

    var allChunksDone: Bool { !chunks.isEmpty && completedChunks == chunks.count }
}
