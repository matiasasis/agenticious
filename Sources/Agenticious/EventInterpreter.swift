import Foundation

/// A stopped response may still be waiting for background work to wake the agent.
@MainActor
enum EventInterpreter {
    static func apply(_ name: String, _ payload: [String: Any], to session: AgentSession) {
        // Claude's hooks carry its session id (a new one after /clear); Codex's notify carries its thread id.
        if let conversation = payload["session_id"] as? String ?? payload["thread-id"] as? String {
            session.conversationID = conversation
        }
        if case .ended = session.status, name != "UserPromptSubmit" {
            let tool = payload["tool"] as? String
            guard name == "mcp", tool == "set_plan" || tool == "set_pull_requests" else { return }
        }
        if (name == "Stop" || name == "codex-notify"), let reason = endedReason(payload) {
            end(reason, in: session)
            return
        }

        if name == "PostToolUse", let response = payload["tool_response"] {
            if let text = response as? String { session.recordPullRequests(in: text) }
            else if JSONSerialization.isValidJSONObject(response),
                    let data = try? JSONSerialization.data(withJSONObject: response, options: .withoutEscapingSlashes) {
                session.recordPullRequests(in: String(decoding: data, as: UTF8.self))
            }
        }
        switch name {
        case "UserPromptSubmit":
            session.status = .working
        case "PreToolUse":
            toolStarted(payload, in: session)
        case "PostToolUse":
            toolFinished(payload, in: session)
        case "Notification":
            notified(payload, session: session)
        case "Stop":
            turnFinished(session, hasBackgroundWork: hasBackgroundWork(payload))
        case "codex-notify":
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
        guard !alreadyNudged, !session.status.isFinished, !session.status.needsAttention,
              endedReason(payload) == nil,
              !hasBackgroundWork(payload), let reason = stopNudge(for: session) else { return nil }

        return ["decision": "block", "reason": reason]
    }

    private static func stopNudge(for session: AgentSession) -> String? {
        let closing = "Then call finish if the whole task is complete, end if work was cancelled or handed off, or need_human if you're waiting on the human. " +
            "Don't repeat your previous answer."

        switch session.planSource {
        case .none:
            return "Agenticious: you haven't posted a plan. Call set_plan with the steps you took (1-2 is fine for a quick " +
                "question), mark each finished one done with update_chunk. " + closing
        case .agent where session.hasOpenChunks:
            return "Agenticious: your plan still has chunks that aren't marked done. Call update_chunk for each chunk " +
                "you finished. " + closing
        default:
            return nil
        }
    }

    // MARK: - Hook events

    private static func hasBackgroundWork(_ payload: [String: Any]) -> Bool {
        let tasks = payload["background_tasks"] as? [[String: Any]] ?? []
        let wakeups = payload["session_crons"] as? [[String: Any]] ?? []
        return !tasks.isEmpty || !wakeups.isEmpty
    }

    private static func toolStarted(_ payload: [String: Any], in session: AgentSession) {
        guard let tool = payload["tool_name"] as? String, !tool.hasPrefix("mcp__agenticious__") else { return }
        guard !isSubagent(payload) else { return subagentProgressed(session) }

        session.isAwaitingPermission = false
        session.status = question(asked: tool, input: payload["tool_input"]).map(SessionStatus.needsYou) ?? .working
    }

    private static func toolFinished(_ payload: [String: Any], in session: AgentSession) {
        let tool = payload["tool_name"] as? String ?? ""
        // Our own MCP calls already set the status; a trailing PostToolUse must not undo a need_human.
        guard !tool.hasPrefix("mcp__agenticious__") else { return }
        guard !isSubagent(payload) else { return subagentProgressed(session) }

        session.isAwaitingPermission = false
        session.status = .working
        if tool == "TodoWrite" { mirrorTodoList(payload, in: session) }
    }

    /// Claude sets `agent_id` only on hooks fired inside a subagent. Its tools say nothing about the main agent,
    /// which may be asking the human or waiting on that subagent, except that a permission prompt was answered.
    private static func isSubagent(_ payload: [String: Any]) -> Bool {
        payload["agent_id"] != nil
    }

    private static func subagentProgressed(_ session: AgentSession) {
        guard session.isAwaitingPermission else { return }
        session.isAwaitingPermission = false
        session.status = .working
    }

    /// Tools that stop and wait for the human, with what they ask.
    private static func question(asked tool: String, input: Any?) -> String? {
        switch tool {
        case "AskUserQuestion":
            let questions = (input as? [String: Any])?["questions"] as? [[String: Any]] ?? []
            return questions.first?["question"] as? String ?? "Answer the agent's question"
        case "ExitPlanMode":
            return "Review the agent's plan"
        default:
            return nil
        }
    }

    private static func notified(_ payload: [String: Any], session: AgentSession) {
        let message = payload["message"] as? String ?? "Needs your input"

        if isIdleReminder(payload, message: message) {
            if !session.status.needsAttention && !session.status.isFinished && session.status != .waiting {
                session.status = .yourTurn
            }
        } else {
            session.isAwaitingPermission = true
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

    private static func turnFinished(_ session: AgentSession, hasBackgroundWork: Bool = false) {
        guard !session.status.isFinished, !session.status.needsAttention else { return }

        if hasBackgroundWork {
            session.status = .waiting
        } else {
            session.status = session.allChunksDone ? .done(nil) : .yourTurn
        }
    }

    // MARK: - agenticious MCP tools

    private static func agentReported(_ payload: [String: Any], in session: AgentSession) {
        let arguments = payload["args"] as? [String: Any] ?? [:]

        switch payload["tool"] as? String {
        case "set_pull_requests":
            session.recordPullRequests(in: (arguments["urls"] as? [String] ?? []).joined(separator: "\n"))
        case "set_plan": setPlan(arguments, in: session)
        case "update_chunk": updateChunk(arguments, in: session)
        case "need_human":
            session.isAwaitingPermission = false
            session.status = .needsYou(arguments["reason"] as? String ?? "Needs your input")
        case "finish": finish(arguments, in: session)
        case "end":
            if let reason = arguments["reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                end(reason, in: session)
            }
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

        let status = ChunkStatus(rawValue: arguments["status"] as? String ?? "")
        session.chunks[position].status = status ?? .inProgress
        session.chunks[position].note = arguments["note"] as? String
        session.recordPullRequests(in: arguments["note"] as? String ?? "")
        if status == .inProgress || !session.status.needsAttention { session.status = .working }
    }

    private static func finish(_ arguments: [String: Any], in session: AgentSession) {
        for index in session.chunks.indices where session.chunks[index].status != .done {
            session.chunks[index].status = .done
        }
        session.recordPullRequests(in: arguments["summary"] as? String ?? "")
        session.status = .done(arguments["summary"] as? String)
    }

    private static func end(_ reason: String, in session: AgentSession) {
        session.recordPullRequests(in: reason)
        session.status = .ended(reason)
    }

    private static func endedReason(_ payload: [String: Any]) -> String? {
        guard let message = payload["last-assistant-message"] as? String ?? payload["last_assistant_message"] as? String else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        let stopped = #"(?i)^(?:[-•]\s*)?(?:stopped here\b|i(?:'ve| have)? stopped (?:work|working)\b|i(?:'ll| will) leave\b[^\n]*\bstop work here\b)"#
        let resolved = #"(?i)\b(?:(?:left|leave)\b[^\n]*\bto (?:the )?(?:other|another) session|at your request|as requested|you (?:asked|directed)|handed (?:it |this |the work )?off|cancelled|canceled)\b"#
        guard !text.contains("?"), text.range(of: stopped, options: .regularExpression) != nil,
              text.range(of: resolved, options: .regularExpression) != nil else { return nil }
        return message
    }
}
