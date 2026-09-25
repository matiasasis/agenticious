import Foundation

/// Turns raw agent events into dashboard state: status, the "needs you" reason, and the chunk boxes.
@MainActor
enum EventInterpreter {
    static func apply(_ name: String, _ payload: [String: Any], to session: AgentSession) {
        switch name {
        case "UserPromptSubmit":
            session.status = .working
        case "PostToolUse":
            toolFinished(payload, in: session)
        case "Notification":
            session.status = .needsYou(payload["message"] as? String ?? "Needs your input")
        case "Stop", "codex-notify":
            turnFinished(session)
        case "mcp":
            agentReported(payload, in: session)
        default:
            break
        }
    }

    // MARK: - Hook events

    private static func toolFinished(_ payload: [String: Any], in session: AgentSession) {
        let tool = payload["tool_name"] as? String ?? ""
        // Our own MCP calls already set the status; a trailing PostToolUse must not undo a need_human.
        guard !tool.hasPrefix("mcp__agentdeck__") else { return }

        session.status = .working
        if tool == "TodoWrite" { mirrorTodoList(payload, in: session) }
    }

    private static func mirrorTodoList(_ payload: [String: Any], in session: AgentSession) {
        guard session.planSource != .agent,
              let input = payload["tool_input"] as? [String: Any],
              let todos = input["todos"] as? [[String: Any]] else { return }

        session.chunks = todos.enumerated().map { index, todo in
            Chunk(id: index + 1, title: todo["content"] as? String ?? "Step \(index + 1)", status: todoStatus(todo["status"]))
        }
        session.planSource = .todoList
    }

    private static func todoStatus(_ raw: Any?) -> ChunkStatus {
        switch raw as? String {
        case "in_progress": .inProgress
        case "completed": .done
        default: .pending
        }
    }

    private static func turnFinished(_ session: AgentSession) {
        if case .done = session.status { return }

        session.status = session.allChunksDone ? .done(nil) : .needsYou("Turn finished, waiting for you")
    }

    // MARK: - agentdeck MCP tools

    private static func agentReported(_ payload: [String: Any], in session: AgentSession) {
        let arguments = payload["args"] as? [String: Any] ?? [:]

        switch payload["tool"] as? String {
        case "set_plan": setPlan(arguments, in: session)
        case "update_chunk": updateChunk(arguments, in: session)
        case "need_human": session.status = .needsYou(arguments["reason"] as? String ?? "Needs your input")
        case "finish": session.status = .done(arguments["summary"] as? String)
        default: break
        }
    }

    private static func setPlan(_ arguments: [String: Any], in session: AgentSession) {
        let items = arguments["chunks"] as? [Any] ?? []
        let previous = Dictionary(session.chunks.map { ($0.title, $0.status) }, uniquingKeysWith: { first, _ in first })

        session.chunks = items.enumerated().map { index, item in
            let title = (item as? [String: Any])?["title"] as? String ?? item as? String ?? "Chunk \(index + 1)"
            return Chunk(id: index + 1, title: title, status: previous[title] ?? .pending)
        }
        session.planSource = .agent
        session.status = .working
    }

    private static func updateChunk(_ arguments: [String: Any], in session: AgentSession) {
        guard let index = (arguments["index"] as? NSNumber)?.intValue,
              let position = session.chunks.firstIndex(where: { $0.id == index }) else { return }

        session.chunks[position].status = ChunkStatus(rawValue: arguments["status"] as? String ?? "") ?? .inProgress
        session.chunks[position].note = arguments["note"] as? String
        if !session.status.needsAttention { session.status = .working }
    }
}
