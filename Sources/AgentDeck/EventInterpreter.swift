import Foundation

/// Turns raw agent events into dashboard state: status, the "needs you" reason, and the chunk boxes.
///
/// What counts as "needs you" (orange, sound, dock badge):
/// - Claude shows a permission prompt (`Notification` hook of type `permission_prompt`)
/// - the agent calls the `need_human` tool
/// A turn that simply ended (`Stop`, Claude's idle reminder, Codex's turn-complete) is only "your turn".
@MainActor
enum EventInterpreter {
    static func apply(_ name: String, _ payload: [String: Any], to session: AgentSession) {
        switch name {
        case "UserPromptSubmit":
            session.status = .working
        case "PostToolUse":
            toolFinished(payload, in: session)
        case "Notification":
            notified(payload, session: session)
        case "Stop", "codex-notify":
            turnFinished(session)
        case "mcp":
            agentReported(payload, in: session)
        default:
            break
        }
    }

    /// Claude's Stop hook can refuse to stop. If the agent never posted a plan, or its plan still has open chunks,
    /// send it back once to report, so the step boxes don't stay empty or grey after it has answered.
    static func stopHookReply(_ payload: [String: Any], for session: AgentSession) -> [String: Any]? {
        let alreadyNudged = payload["stop_hook_active"] as? Bool ?? false
        guard !alreadyNudged, !session.status.isFinished, let reason = stopNudge(for: session) else { return nil }

        return ["decision": "block", "reason": reason]
    }

    private static func stopNudge(for session: AgentSession) -> String? {
        let closing = "Then call finish if the whole task is complete, or need_human if you're waiting on the human. " +
            "Don't repeat your previous answer."

        switch session.planSource {
        case .none:
            return "AgentDeck: you haven't posted a plan. Call set_plan with the steps you took (1-2 is fine for a quick " +
                "question), mark each finished one done with update_chunk. " + closing
        case .agent where session.hasOpenChunks:
            return "AgentDeck: your plan still has chunks that aren't marked done. Call update_chunk for each chunk " +
                "you finished. " + closing
        default:
            return nil
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

    private static func notified(_ payload: [String: Any], session: AgentSession) {
        let message = payload["message"] as? String ?? "Needs your input"

        if isIdleReminder(payload, message: message) {
            if !session.status.needsAttention && !session.status.isFinished { session.status = .yourTurn }
        } else {
            session.status = .needsYou(message)
        }
    }

    private static func isIdleReminder(_ payload: [String: Any], message: String) -> Bool {
        payload["notification_type"] as? String == "idle_prompt" || message.localizedCaseInsensitiveContains("waiting for your input")
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
        guard !session.status.isFinished, !session.status.needsAttention else { return }

        session.status = session.allChunksDone ? .done(nil) : .yourTurn
    }

    // MARK: - agentdeck MCP tools

    private static func agentReported(_ payload: [String: Any], in session: AgentSession) {
        let arguments = payload["args"] as? [String: Any] ?? [:]

        switch payload["tool"] as? String {
        case "set_plan": setPlan(arguments, in: session)
        case "update_chunk": updateChunk(arguments, in: session)
        case "need_human": session.status = .needsYou(arguments["reason"] as? String ?? "Needs your input")
        case "finish": finish(arguments, in: session)
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

    private static func finish(_ arguments: [String: Any], in session: AgentSession) {
        for index in session.chunks.indices where session.chunks[index].status != .done {
            session.chunks[index].status = .done
        }
        session.status = .done(arguments["summary"] as? String)
    }
}
