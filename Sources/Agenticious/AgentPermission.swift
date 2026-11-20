import Foundation

/// One tool call Claude wants the human's say-so for, from its PermissionRequest hook.
struct PermissionRequest: Identifiable {
    /// Minted here: the hook carries no tool_use_id, and a card, a click and a reply must all name the same request.
    let id: UUID
    let toolName: String
    let input: [String: Any]
    /// Where Claude was working when it asked.
    let directory: String?
    /// Set when a subagent asks.
    let agentID: String?
    let agentType: String?
    /// Claude's own "don't ask again" suggestions, exactly as received.
    let suggestions: [[String: Any]]
    /// Claude Code sent a command with an empty list of suggestions, which it does when its own menu carries a safety
    /// warning. The warning's text never reaches a hook, so the card can only say there may be one.
    let hasTerminalOnlyWarning: Bool
    /// From the PreToolUse that came just before, when it was seen: ties the request to the PostToolUse that ends it.
    var toolUseID: String?

    var isFromSubagent: Bool { agentID != nil }
    var fingerprint: String { Self.fingerprint(tool: toolName, input: input, agentID: agentID) }

    /// Tools whose prompt only Claude's own menu can answer: a bare allow is ignored for them, and our own never ask.
    static func passesThrough(_ tool: String) -> Bool {
        ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode"].contains(tool) || tool.hasPrefix("mcp__agenticious__")
    }

    static func parse(_ payload: [String: Any], id: UUID = UUID()) -> PermissionRequest? {
        guard let tool = payload["tool_name"] as? String, !tool.isEmpty, !passesThrough(tool),
              let input = payload["tool_input"] as? [String: Any] else { return nil }
        return PermissionRequest(id: id, toolName: tool, input: input, directory: payload["cwd"] as? String,
                                 agentID: agentID(in: payload),
                                 agentType: (payload["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 suggestions: payload["permission_suggestions"] as? [[String: Any]] ?? [],
                                 hasTerminalOnlyWarning: tool == "Bash" && (payload["permission_suggestions"] as? [Any])?.isEmpty == true,
                                 toolUseID: nil)
    }

    static func agentID(in payload: [String: Any]) -> String? {
        (payload["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The same for the PreToolUse, PermissionRequest and PostToolUse of one call: who, which tool, which input.
    static func fingerprint(tool: String, input: Any?, agentID: String?) -> String {
        let canonical = input.flatMap { JSONSerialization.isValidJSONObject($0) ? $0 : nil }
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [agentID ?? "", tool, canonical].joined(separator: "\u{1F}")
    }

    static func fingerprint(of payload: [String: Any]) -> String {
        fingerprint(tool: payload["tool_name"] as? String ?? "", input: payload["tool_input"], agentID: agentID(in: payload))
    }

    /// The held requests a later hook proves finished or abandoned. They get an empty reply, never a decision.
    static func ended(by event: String, _ payload: [String: Any], among pending: [PermissionRequest]) -> Set<UUID> {
        let agentID = agentID(in: payload)
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            let toolUseID = payload["tool_use_id"] as? String
            let fingerprint = fingerprint(of: payload)
            // One finished call ends one request: the oldest that matches.
            let match = pending.first { request in
                if let known = request.toolUseID, let toolUseID { return known == toolUseID }
                return request.fingerprint == fingerprint
            }
            return Set([match?.id].compactMap { $0 })
        case "Stop", "UserPromptSubmit":
            // The main agent's turn ended or a new one began: nothing of its own can still be asking. Its background
            // subagents can, so theirs stay.
            return agentID == nil ? Set(pending.filter { !$0.isFromSubagent }.map(\.id)) : []
        case "SubagentStop":
            return agentID == nil ? [] : Set(pending.filter { $0.agentID == agentID }.map(\.id))
        default:
            return []
        }
    }

    // MARK: - Replies

    /// What the hook prints for a decision. Never carries `updatedInput`: what runs is what the card showed.
    func hookReply(for decision: PermissionDecision) -> Data? {
        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .allowAlways:
            body = ["behavior": "allow"]
            if alwaysAllow != nil { body["updatedPermissions"] = suggestions }
        case let .deny(note):
            let note = Self.trimmed(note)
            body = ["behavior": "deny", "message": Self.denyMessage(note: note)]
            // Like No in Claude's own menu. Never for a subagent: what an interrupt does there is untested.
            if note.isEmpty, !isFromSubagent { body["interrupt"] = true }
        }
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body]],
                                           options: [.sortedKeys])
    }

    /// Whether this denial ends Claude's turn, after which no hook fires.
    func stopsTurn(_ decision: PermissionDecision) -> Bool {
        if case let .deny(note) = decision { return Self.trimmed(note).isEmpty && !isFromSubagent }
        return false
    }

    /// The most of a note Claude is sent. The card says when a note runs past it.
    static let noteLimit = 2_000

    private static func trimmed(_ note: String) -> String {
        String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(noteLimit))
    }

    static func denyMessage(note: String) -> String {
        guard !note.isEmpty else { return "The user denied this tool use in Agenticious." }
        return "The user doesn't want to proceed with this tool use. The tool use was rejected. To tell you how to proceed, the user said:\n\(note)"
    }

    /// Claude's suggestions as one "don't ask again" choice: offered only when every one of them adds allow rules,
    /// all for this session or all for this folder's own local settings. Mode changes, extra folders and shared or
    /// global settings stay in the terminal, and so does any entry with a field this can't put into words, or a mix
    /// of the two places (one sentence could not say which rule goes where): the reply echoes the suggestions
    /// whole, so the row has to say everything they do.
    struct AlwaysAllow: Equatable {
        let rules: [String]
        let scope: String
    }

    var alwaysAllow: AlwaysAllow? {
        var names: [String] = [], place: String?
        for entry in suggestions {
            guard entry["type"] as? String == "addRules", entry["behavior"] as? String == "allow",
                  Set(entry.keys).isSubset(of: ["type", "behavior", "destination", "rules"]),
                  let destination = entry["destination"] as? String, ["session", "localSettings"].contains(destination),
                  place == nil || place == destination,
                  let rules = entry["rules"] as? [[String: Any]], !rules.isEmpty else { return nil }
            place = destination
            for rule in rules {
                guard let tool = (rule["toolName"] as? String).map({ PermissionText.visible($0) }), !tool.isEmpty,
                      Set(rule.keys).isSubset(of: ["toolName", "ruleContent"]) else { return nil }
                guard let content = rule["ruleContent"] else { names.append(tool); continue }
                guard let content = content as? String else { return nil }
                names.append("\(tool)(\(PermissionText.visible(content)))")
            }
        }
        guard let place else { return nil }
        return AlwaysAllow(rules: names, scope: place == "session" ? "for this session" : "saved in this folder's .claude/settings.local.json")
    }

    // MARK: - Wording

    var title: String {
        switch toolName {
        case "Bash": "Run command"
        case "Edit", "MultiEdit", "NotebookEdit": "Edit file"
        case "Write": "Write file"
        case "Read": "Read file"
        case "WebFetch": "Fetch URL"
        case "WebSearch": "Search the web"
        default: PermissionText.visible(toolName.replacingOccurrences(of: "mcp__", with: "MCP · ").replacingOccurrences(of: "__", with: " · "))
        }
    }

    /// "Run command · touch notes.txt", for the status line; a subagent's says whose it is. One line of the subject,
    /// which says so when there is more: the rest of a command is where the card is.
    var summary: String {
        let subject = (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? input["command"] as? String ?? input["url"] as? String ?? input["query"] as? String ?? input["pattern"] as? String
        let lines = subject?.split(whereSeparator: \.isNewline) ?? []
        let line = lines.first.map { first in
            PermissionText.visible(String(first.prefix(120))) + (first.count > 120 ? "…" : "")
                + (lines.count > 1 ? " (+\(lines.count - 1) more \(lines.count == 2 ? "line" : "lines"))" : "")
        }
        let what = [title, line].compactMap { $0 }.joined(separator: " · ")
        return isFromSubagent ? "\(agentType.map { "\(PermissionText.visible($0)) subagent" } ?? "Subagent") · \(what)" : what
    }

    func statusReason(waiting: Int) -> String { waiting > 0 ? "\(summary) · \(waiting) more waiting" : summary }
    var terminalReason: String { "\(summary) · answer in the terminal" }
}

enum PermissionDecision: Equatable {
    case allow
    /// Allow, and apply Claude's own suggestions as received.
    case allowAlways
    /// With a note Claude reads it and carries on; without one its turn ends, like No in its own menu.
    case deny(note: String)
}

/// A PermissionRequest hook held open while its card shows in Activity. An empty reply hands it back to Claude's menu.
struct PendingPermission: Identifiable {
    var request: PermissionRequest
    let respond: (Data?) -> Void
    var id: UUID { request.id }
}

struct OpenToolCall {
    let toolUseID: String
    let fingerprint: String
    let isFromSubagent: Bool
}

enum PermissionText {
    /// Characters that can hide or reorder what a command says are shown as what they are. Decided by Unicode
    /// property, not by a list: a list misses the next invisible character.
    /// `prose` is for Claude's own words, which never run: there the blanks and joiners ordinary writing uses (French
    /// and CJK spacing, Persian and Indic joiners, emoji) are left as they are. Commands, paths and file contents
    /// never pass it.
    static func visible(_ text: String, prose: Bool = false) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Printable ASCII first: this runs over whole file contents.
            case 0x09, 0x0A, 0x20...0x7E: result.append(scalar)
            case 0x0D: result.append("␍")
            case 0x1B: result.append("␛")
            default:
                if isHidden(scalar, prose: prose) { result.append(contentsOf: String(format: "⟨U+%04X⟩", scalar.value).unicodeScalars) }
                else { result.append(scalar) }
            }
        }
        return String(result)
    }

    /// Draws nothing, or changes how its neighbours are drawn. Emoji selectors and joiners count, and so does every
    /// blank that is not the ordinary space (a trailing no-break space is part of a file name to the shell): a card
    /// that reads oddly is better than one that hides a byte.
    private static func isHidden(_ scalar: Unicode.Scalar, prose: Bool) -> Bool {
        if prose, [0xA0, 0x202F, 0x3000, 0x200C, 0x200D, 0xFE0F].contains(scalar.value) { return false }
        let properties = scalar.properties
        switch properties.generalCategory {
        case .control, .format, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator: return true
        default:
            // Braille blank and the object replacement character are neither spaces nor ignorable, and draw no ink.
            return properties.isDefaultIgnorableCodePoint || properties.isVariationSelector || properties.isBidiControl
                || scalar.value == 0x2800 || scalar.value == 0xFFFC
        }
    }

    /// What a text view lays out without stalling. Past it the middle goes, and the card says so.
    static func bounded(_ text: String, limit: Int = 60_000) -> (text: String, omitted: Int) {
        guard text.count > limit else { return (text, 0) }
        let head = limit * 2 / 3, tail = limit - head
        let omitted = text.count - limit
        return (text.prefix(head) + "\n⋯ \(omitted) characters not shown ⋯\n" + text.suffix(tail), omitted)
    }
}

/// Every change to a session's held permission requests. `decide` is the only place a decision is sent; every
/// other path answers empty, which Claude reads as "no decision" and falls back to its own menu.
@MainActor
enum PermissionInterpreter {
    /// Past this many held at once, further requests go straight to Claude's own menu.
    static let limit = 12

    /// Holds the hook and queues a card, or answers empty at once so Claude's own menu is the only way.
    /// Returns the request's id, to drop it if the hook hangs up.
    @discardableResult
    static func hold(_ payload: [String: Any], in session: AgentSession, respond: @escaping (Data?) -> Void) -> UUID? {
        var isEnded = false
        if case .ended = session.status { isEnded = true }
        guard session.agent == .claude, session.isRunning, !session.isMarkedFinished, !isEnded,
              session.startupPrompt == nil, var request = PermissionRequest.parse(payload) else {
            respond(nil)
            return nil
        }
        request.toolUseID = session.toolUseID(matching: request.fingerprint)
        session.hold(PendingPermission(request: request, respond: respond))
        // No card for it, yet its menu is up in the terminal now: recorded as a hand-over, so nothing reopens the
        // reply box onto it and only its own progress settles the wait.
        guard !session.isArchiving, session.pendingPermissions.count <= limit else {
            handToTerminal([request.id], in: session)
            return nil
        }
        session.lastActivity = Date()
        return request.id
    }

    /// Sends the human's decision for a request that is still held: a second click, or a click on a card released a
    /// moment ago, finds nothing and does nothing.
    @discardableResult
    static func decide(_ decision: PermissionDecision, on id: UUID, in session: AgentSession) -> Bool {
        guard let pending = session.takePermission(id) else { return false }
        pending.respond(pending.request.hookReply(for: decision))
        // A subagent's answer says nothing about what the main agent is doing.
        guard !pending.request.isFromSubagent else { return true }
        if pending.request.stopsTurn(decision) {
            // Claude ends the turn without a Stop hook, so nothing else of the main agent can still be asking.
            session.releasePermissions { !$0.isFromSubagent }
            session.forgetMainToolCalls()
            session.isAwaitingPermission = false
            if !session.status.isFinished {
                session.status = .yourTurn
                // A subagent's menu handed to the terminal earlier is still there: this answer was not for it.
                if let menu = session.terminalMenus.first { awaitTerminal(.permissionRequired(menu.terminalReason), in: session) }
            }
        } else {
            settleAnsweredPrompt(in: session)
        }
        return true
    }

    /// The human picked Claude's own menu with the card's button. Nothing else says the menu waits there (a
    /// subagent's only appears now), so the wait is stored.
    static func handToTerminal(_ ids: [UUID], in session: AgentSession) {
        let handed = ids.compactMap { session.takePermission($0) }
        for pending in handed {
            pending.respond(nil)
            session.awaitTerminalMenu(for: pending.request)
        }
        if let first = handed.first?.request {
            awaitTerminal(.permissionRequired(first.terminalReason), isMainAgents: !first.isFromSubagent, in: session)
        }
    }

    /// A key typed in the terminal, where the main agent's menu already shows. Whether it answered the menu is unknown,
    /// so only the cards go and the status stays what Claude's hooks say: Working, then its own notice six seconds in.
    static func typedInTerminal(in session: AgentSession) {
        let released = session.releasePermissions { !$0.isFromSubagent }
        // Unless that status would open the reply box onto a menu the key may have left up: then the wait is stored.
        if let first = released.first, session.statusOpensReplyBox {
            awaitTerminal(.permissionRequired(first.terminalReason), isMainAgents: true, in: session)
        }
    }

    /// The hook hung up before any reply: the prompt was dismissed where we could not see, or the hook timed out
    /// with the menu still up. Which one is unknown, so the reply box stays closed.
    static func hookClosed(_ id: UUID, in session: AgentSession) {
        guard let pending = session.takePermission(id) else { return }
        // A subagent's menu shows only after its hook ends; Claude's own notification reports it if it does.
        guard !pending.request.isFromSubagent else { return }
        awaitTerminal(.needsYou("The permission prompt closed in the terminal (\(pending.request.summary)). Continue there."),
                      isMainAgents: true, in: session)
    }

    /// Run on every hook before the status is worked out: releases what the event proves over.
    static func observe(_ event: String, _ payload: [String: Any], in session: AgentSession) {
        session.trackToolCall(event, payload)
        session.settleTerminalMenus(event, payload)
        let turnBoundary = (event == "Stop" || event == "UserPromptSubmit") && PermissionRequest.agentID(in: payload) == nil
        if turnBoundary { session.forgetMainToolCalls() }
        let over = PermissionRequest.ended(by: event, payload, among: session.pendingPermissions.map(\.request))
        let released = session.releasePermissions { over.contains($0.id) }
        guard turnBoundary else { return }
        // The turn ending answers a card released just now and a menu of the main agent's handed over earlier alike.
        // Never merely because nothing is held: the wait may be a subagent's menu, which outlives the parent's turn,
        // so a subagent's wait settles here only once none of the menus handed over is left.
        if released.contains(where: { !$0.isFromSubagent }) || session.status == session.mainAgentTerminalWait
            || (session.terminalMenus.isEmpty && session.status == session.subagentTerminalWait) {
            settleAnsweredPrompt(in: session)
        }
    }

    /// Archiving hands every card back to Claude's menus. Its process normally goes with it, but if it outlives a
    /// failed archive, the reply box must not type into a menu that is now up: the same rule as a typed key.
    static func releaseForArchive(in session: AgentSession) {
        let released = session.releaseHeldRequests()
        released.filter(\.isFromSubagent).forEach(session.awaitTerminalMenu)
        if let first = released.first(where: { !$0.isFromSubagent }), session.statusOpensReplyBox {
            awaitTerminal(.permissionRequired(first.terminalReason), isMainAgents: true, in: session)
        }
    }

    /// The terminal is now the only place to answer: attention, and no typing into a menu. A wait of the main
    /// agent's is remembered, so the end of its turn can settle it.
    private static func awaitTerminal(_ status: SessionStatus, isMainAgents: Bool = false, in session: AgentSession) {
        if case .ended = session.status { return }
        guard session.isRunning else { return }
        session.isAwaitingPermission = true
        session.status = status
        session.mainAgentTerminalWait = isMainAgents ? status : nil
        session.subagentTerminalWait = isMainAgents ? nil : status
    }

    /// Claude's six-second "needs your permission" notification landed while the card was up, or the main agent's
    /// menu was left to the terminal; either is answered now.
    private static func settleAnsweredPrompt(in session: AgentSession) {
        guard session.isAwaitingPermission, session.pendingPermissions.allSatisfy(\.request.isFromSubagent) else { return }
        session.isAwaitingPermission = false
        session.status = .working
        session.mainAgentTerminalWait = nil
        session.subagentTerminalWait = nil
    }
}

extension PermissionRequest {
    /// One labelled piece of what the call would do, shown in the card in reading order.
    struct Part: Equatable, Identifiable {
        enum Kind { case code, removed, prose }
        let label: String
        let text: String
        var kind = Kind.code
        var id: String { label }
    }

    /// The file the call would touch, when it names one.
    var file: String? { input["file_path"] as? String ?? input["notebook_path"] as? String }

    /// Claude asked for this command to run outside Claude Code's sandbox, which its own menu titles "unsandboxed".
    /// Whether a sandbox is on at all is not something a hook is told.
    var asksToLeaveSandbox: Bool { toolName == "Bash" && input["dangerouslyDisableSandbox"] as? Bool == true }

    /// What the call would do. Any tool or shape this doesn't know is shown whole, as Claude sent it, and so is
    /// every key of a known shape that the card doesn't put into words: Allow approves the whole input.
    var parts: [Part] {
        var shown: Set<String> = []
        func text(_ key: String) -> String? {
            guard let value = input[key] as? String else { return nil }
            shown.insert(key)
            return value
        }
        var named: [Part]?
        switch toolName {
        case "Bash":
            if let command = text("command") {
                // The description is Claude's own account of the command, not a fact about it.
                named = [Part(label: "Command", text: command)]
                    + (text("description").map { [Part(label: "Claude says", text: $0, kind: .prose)] } ?? [])
            }
        case "Edit":
            if text("file_path") != nil, let old = text("old_string"), let new = text("new_string") {
                let everywhere = input["replace_all"] as? Bool
                if everywhere != nil { shown.insert("replace_all") }
                named = [Part(label: everywhere == true ? "Replace every occurrence of" : "Replace", text: old, kind: .removed),
                         Part(label: "With", text: new)]
            }
        case "Write":
            if text("file_path") != nil, let content = text("content") { named = [Part(label: "New contents", text: content)] }
        case "Read":
            if text("file_path") != nil { named = [] }
        case "WebFetch":
            if let url = text("url") {
                named = [Part(label: "URL", text: url)]
                    + (text("prompt").map { [Part(label: "What Claude asks of the page", text: $0, kind: .prose)] } ?? [])
            }
        default:
            break
        }
        guard let named else { return [Part(label: "Input, as Claude sent it", text: Self.pretty(input))] }
        let rest = input.filter { !shown.contains($0.key) }
        return named + (rest.isEmpty ? [] : [Part(label: "Also sent", text: Self.pretty(rest))])
    }

    static func pretty(_ input: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(input),
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return String(describing: input) }
        return String(decoding: data, as: UTF8.self)
    }
}
