import Foundation

struct LaunchSpec {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let directory: String
}

/// Builds the command line for an agent, wired so that it reports back to the EventServer:
/// hooks/notify for "turn finished" and "needs permission", and the agenticious MCP server for the chunk plan.
struct AgentLauncher {
    let port: UInt16

    func spec(for session: AgentSession) throws -> LaunchSpec {
        var variables = baseEnvironment(for: session)
        let command: String

        switch session.agent {
        case .claude:
            let files = try writeClaudeFiles(for: session)
            variables["AD_SETTINGS"] = files.settings
            variables["AD_MCP"] = files.mcp
            variables["AD_SYSPROMPT"] = ChunkingPrompt.text
            variables["AD_PROMPT"] = session.prompt
            command = #"exec claude --settings "$AD_SETTINGS" --mcp-config "$AD_MCP" --append-system-prompt "$AD_SYSPROMPT""#
                + modelFlags(for: session, into: &variables) + #" -- "$AD_PROMPT""#
        case .codex:
            variables["AD_MCP_CMD"] = #"mcp_servers.agenticious.command="\#(tomlEscaped(mcpBinary))""#
            variables["AD_MCP_ENV"] = #"mcp_servers.agenticious.env={AGENTICIOUS_SESSION="\#(session.id.uuidString)",AGENTICIOUS_PORT="\#(port)"}"#
            variables["AD_NOTIFY"] = #"notify=['/bin/sh','-c','curl -s -m 2 -X POST --data-binary "$1" \#(hookURL(session, "codex-notify")) >/dev/null 2>&1','sh']"#
            variables["AD_PROMPT"] = ChunkingPrompt.inlined(with: session.prompt)
            command = #"exec codex -c "$AD_MCP_CMD" -c "$AD_MCP_ENV" -c "$AD_NOTIFY""#
                + modelFlags(for: session, into: &variables) + #" -- "$AD_PROMPT""#
        }

        // A login + interactive shell picks up the user's PATH (nodenv, ~/.local/bin, …), which a GUI app doesn't inherit.
        // Every user-supplied string goes through an env var, so nothing needs shell quoting.
        return LaunchSpec(
            executable: "/bin/zsh",
            arguments: ["-lic", command],
            environment: variables.map { "\($0.key)=\($0.value)" },
            directory: session.directory.path
        )
    }

    /// Claude takes `--model` / `--effort`; Codex takes `-m` and the `model_reasoning_effort` config key.
    private func modelFlags(for session: AgentSession, into variables: inout [String: String]) -> String {
        var flags = ""
        if let model = session.model {
            variables["AD_MODEL"] = model.id
            flags += session.agent == .claude ? #" --model "$AD_MODEL""# : #" -m "$AD_MODEL""#
        }
        if let effort = session.effort {
            variables["AD_EFFORT"] = session.agent == .claude ? effort : #"model_reasoning_effort="\#(tomlEscaped(effort))""#
            flags += session.agent == .claude ? #" --effort "$AD_EFFORT""# : #" -c "$AD_EFFORT""#
        }
        return flags
    }

    // MARK: - Environment

    private func baseEnvironment(for session: AgentSession) -> [String: String] {
        // If Agenticious was started from inside a Claude Code session, its markers would make every agent a
        // "child session" with transcript saving off. The login shell re-exports any CLAUDE_CODE_* the user sets.
        var variables = ProcessInfo.processInfo.environment.filter { key, _ in
            key != "CLAUDECODE" && !key.hasPrefix("CLAUDE_CODE_")
        }
        variables["TERM"] = "xterm-256color"
        variables["COLORTERM"] = "truecolor"
        variables["AGENTICIOUS_SESSION"] = session.id.uuidString
        variables["AGENTICIOUS_PORT"] = String(port)
        return variables
    }

    // MARK: - Claude Code

    private func writeClaudeFiles(for session: AgentSession) throws -> (settings: String, mcp: String) {
        let directory = try sessionDirectory(for: session)
        let settingsURL = directory.appendingPathComponent("settings.json")
        let mcpURL = directory.appendingPathComponent("mcp.json")

        try json(claudeSettings(for: session)).write(to: settingsURL)
        try json(mcpConfig(for: session)).write(to: mcpURL)

        return (settingsURL.path, mcpURL.path)
    }

    private func claudeSettings(for session: AgentSession) -> [String: Any] {
        [
            "hooks": [
                "UserPromptSubmit": [hookEntry(session, "UserPromptSubmit")],
                "PostToolUse": [hookEntry(session, "PostToolUse", matcher: "*")],
                "Notification": [hookEntry(session, "Notification")],
                "Stop": [hookEntry(session, "Stop", passReplyToClaude: true)],
            ],
            // Reporting progress must never cost the human a permission prompt.
            "permissions": ["allow": ["mcp__agenticious"]],
            // Claude Code hands the status line its plan limits; the app records them and answers with the line to show.
            "statusLine": ["type": "command", "command": "curl -s -m 2 -X POST --data-binary @- '\(hookURL(session, "StatusLine"))' 2>/dev/null || true"],
        ]
    }

    /// With `passReplyToClaude`, the app's HTTP response becomes the hook's stdout, which Claude reads as a decision.
    private func hookEntry(_ session: AgentSession, _ event: String, matcher: String? = nil, passReplyToClaude: Bool = false) -> [String: Any] {
        let output = passReplyToClaude ? "2>/dev/null" : ">/dev/null 2>&1"
        let command = "curl -s -m 5 -X POST --data-binary @- '\(hookURL(session, event))' \(output) || true"
        var entry: [String: Any] = ["hooks": [["type": "command", "command": command]]]
        if let matcher { entry["matcher"] = matcher }
        return entry
    }

    private func mcpConfig(for session: AgentSession) -> [String: Any] {
        [
            "mcpServers": [
                "agenticious": [
                    "command": mcpBinary,
                    "env": ["AGENTICIOUS_SESSION": session.id.uuidString, "AGENTICIOUS_PORT": String(port)],
                ],
            ],
        ]
    }

    // MARK: - Helpers

    /// The MCP server ships as a sibling executable of the app (both come out of `swift build`).
    private var mcpBinary: String {
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("agenticious-mcp").path
    }

    private func hookURL(_ session: AgentSession, _ event: String) -> String {
        "http://127.0.0.1:\(port)/hook/\(session.id.uuidString)/\(event)"
    }

    private func sessionDirectory(for session: AgentSession) throws -> URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agenticious/sessions/\(session.id.uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    }

    private func tomlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
