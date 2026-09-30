import Foundation
import Combine
import Darwin

struct ProviderCheck: Identifiable {
    let id: String
    let message: String
    var needsAttention = false
    var serverName: String?
    var isClaudeAIConnector = false
}

struct ProviderReport {
    var checks: [ProviderCheck] = []
    var checkedAt: Date?
    var attentionCount: Int { checks.filter(\.needsAttention).count }
}

@MainActor
final class ProviderDiagnostics: ObservableObject {
    @Published private(set) var reports: [AgentKind: ProviderReport] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var isDisconnecting = false
    @Published var disconnectError: String?
    @Published var project = Project.none
    private(set) var lastChecked: Date?

    var attentionCount: Int { reports.values.reduce(0) { $0 + $1.attentionCount } }

    var isBusy: Bool { isChecking || isDisconnecting }

    func disconnect(_ server: String, from agent: AgentKind) async {
        guard !isBusy else { return }
        isDisconnecting = true
        disconnectError = nil
        let directory = project.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        disconnectError = await Task.detached {
            ProviderProbe.disconnect(server, from: agent, directory: directory)
        }.value
        isDisconnecting = false
        await refresh()
    }

    func refresh() async {
        guard !isBusy else { return }
        isChecking = true
        reports = [:]
        let directory = project.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        await withTaskGroup(of: (AgentKind, ProviderReport).self) { group in
            for agent in AgentKind.allCases {
                group.addTask { (agent, ProviderProbe.check(agent, directory: directory)) }
            }
            for await (agent, report) in group { reports[agent] = report }
        }
        lastChecked = Date()
        isChecking = false
    }
}

enum ProviderProbe {
    static func disconnect(_ server: String, from agent: AgentKind, directory: String,
                           run: (String, String) -> DiagnosticCommand.Result = { DiagnosticCommand.run($0, directory: $1) }) -> String? {
        let executable = agent == .claude ? "claude" : "codex"
        let quotedName = "'" + server.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let result = run("\(executable) mcp remove -- \(quotedName)", directory)
        guard result.failure == nil, result.exitCode == 0 else {
            return "Could not disconnect this server. Check its configuration scope and permissions with the provider CLI in the selected folder, then refresh."
        }
        return nil
    }

    static func check(_ agent: AgentKind, directory: String) -> ProviderReport {
        let authCommand = agent == .claude ? "claude auth status --json" : "codex login status"
        let mcpCommand = agent == .claude ? "claude mcp list" : "codex mcp list --json"
        let auth = DiagnosticCommand.run(authCommand, directory: directory)
        let mcp = DiagnosticCommand.run(mcpCommand, directory: directory)
        var checks = [authentication(agent, result: auth)]
        checks += servers(agent, result: mcp)
        if auth.hasWarning || mcp.hasWarning {
            checks.append(ProviderCheck(id: "CLI warning", message: "The provider CLI reported a warning. Run its status commands in this folder to inspect the details.", needsAttention: true))
        }
        return ProviderReport(checks: checks, checkedAt: Date())
    }

    static func authentication(_ agent: AgentKind, result: DiagnosticCommand.Result) -> ProviderCheck {
        if let failure = result.failure { return ProviderCheck(id: "Account", message: failure, needsAttention: true) }
        if agent == .claude,
           let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
           let loggedIn = json["loggedIn"] as? Bool {
            return ProviderCheck(id: "Account", message: loggedIn ? "Signed in" : "Sign-in required · run claude auth login", needsAttention: !loggedIn)
        }
        let output = result.output + result.error
        if agent == .codex, result.exitCode == 0, output.localizedCaseInsensitiveContains("logged in") {
            return ProviderCheck(id: "Account", message: "Signed in")
        }
        if agent == .codex, output.localizedCaseInsensitiveContains("not logged in") {
            return ProviderCheck(id: "Account", message: "Sign-in required · run codex login", needsAttention: true)
        }
        return ProviderCheck(id: "Account", message: "Could not verify sign-in. Check the provider CLI installation and login.", needsAttention: true)
    }

    static func servers(_ agent: AgentKind, result: DiagnosticCommand.Result) -> [ProviderCheck] {
        if let failure = result.failure { return [ProviderCheck(id: "MCP", message: failure, needsAttention: true)] }
        guard result.exitCode == 0 else {
            return [ProviderCheck(id: "MCP", message: "Could not list servers. Run the MCP status command in this folder.", needsAttention: true)]
        }
        if agent == .codex {
            guard let entries = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [[String: Any]],
                  entries.allSatisfy({ $0["name"] is String }) else { return unreadableServers }
            return entries.isEmpty ? [ProviderCheck(id: "MCP", message: "No configured servers")] : entries.map { entry in
                let name = entry["name"] as? String ?? "MCP"
                if entry["enabled"] as? Bool == false { return ProviderCheck(id: name, message: "Disabled", serverName: name) }
                switch entry["auth_status"] as? String {
                case "not_logged_in": return ProviderCheck(id: name, message: "Authentication required · run codex mcp login with this server name", needsAttention: true, serverName: name)
                case "o_auth": return ProviderCheck(id: name, message: "OAuth configured · connection not checked", serverName: name)
                case "bearer_token": return ProviderCheck(id: name, message: "Token configured · connection not checked", serverName: name)
                default: return ProviderCheck(id: name, message: "Authentication not reported · connection not checked", serverName: name)
                }
            }
        }
        let rows = result.output.components(separatedBy: .newlines).compactMap { line -> ProviderCheck? in
            guard let separator = line.range(of: ": ") else { return nil }
            let name = String(line[..<separator.lowerBound])
            let status = String(line[separator.upperBound...])
            if status.contains("✔ Connected") { return ProviderCheck(id: name, message: "Connected", serverName: name) }
            if status.contains("Needs authentication") || status.contains("Needs auth") {
                return ProviderCheck(id: name, message: "Authentication required · open /mcp in Claude Code", needsAttention: true, serverName: name)
            }
            if status.contains("Failed to connect") {
                let reason: String
                if status.contains("Incompatible auth server") { reason = "Incompatible authentication server" }
                else if status.contains("HTTP 404") { reason = "MCP endpoint not found (404)" }
                else { reason = "Connection failed" }
                return ProviderCheck(id: name, message: reason + " · open /mcp in Claude Code", needsAttention: true, serverName: name)
            }
            if status.contains("Pending approval") { return ProviderCheck(id: name, message: "Pending approval · open /mcp in Claude Code", needsAttention: true, serverName: name) }
            if status.localizedCaseInsensitiveContains("disabled") { return ProviderCheck(id: name, message: "Disabled", serverName: name) }
            return ProviderCheck(id: name, message: "Status not recognized · check /mcp in Claude Code", needsAttention: true, serverName: name)
        }
        if !rows.isEmpty {
            return rows.map { row in
                var check = row
                check.isClaudeAIConnector = check.id.hasPrefix("claude.ai ")
                return check
            }
        }
        if result.output.localizedCaseInsensitiveContains("no mcp servers") { return [ProviderCheck(id: "MCP", message: "No configured servers")] }
        return unreadableServers
    }

    private static var unreadableServers: [ProviderCheck] {
        [ProviderCheck(id: "MCP", message: "Could not read server status from this CLI version.", needsAttention: true)]
    }
}

enum DiagnosticCommand {
    struct Result {
        var output = ""
        var error = ""
        var exitCode: Int32 = 0
        var failure: String?
        var hasWarning: Bool { (output + error).localizedCaseInsensitiveContains("warning:") }
    }

    static func run(_ command: String, directory: String, timeout: TimeInterval = 35) -> Result {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let outputURL = folder.appendingPathComponent("stdout")
            let errorURL = folder.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Background checks inherit the app’s terminal; job control would stop them with SIGTTOU.
            process.arguments = ["-l", "-i", "+m", "-c", "exec " + command]
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard !process.isRunning else {
                process.terminate()
                Thread.sleep(forTimeInterval: 0.2)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return Result(failure: "Check timed out. Retry or inspect the provider CLI.")
            }
            return Result(output: read(outputURL), error: read(errorURL), exitCode: process.terminationStatus)
        } catch {
            return Result(failure: "Unable to launch the check. Verify the CLI installation and selected folder.")
        }
    }

    private static func read(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: 1_048_576)) ?? Data(), as: UTF8.self)
    }
}
