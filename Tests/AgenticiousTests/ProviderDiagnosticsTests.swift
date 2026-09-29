import XCTest
@testable import Agenticious

final class ProviderDiagnosticsTests: XCTestCase {
    func testDisconnectUsesProviderAndSelectedDirectory() {
        for (agent, executable) in [(AgentKind.claude, "claude"), (.codex, "codex")] {
            let error = ProviderProbe.disconnect("docs", from: agent, directory: "/tmp/project") { command, directory in
                XCTAssertEqual(command, "\(executable) mcp remove -- 'docs'")
                XCTAssertEqual(directory, "/tmp/project")
                return .init()
            }
            XCTAssertNil(error)
        }
    }

    func testDisconnectQuotesServerNameAsOneLiteralArgument() {
        let name = "-docs' $(printf injected); `printf injected`"
        let error = ProviderProbe.disconnect(name, from: .codex, directory: "/tmp") { command, directory in
            let arguments = String(command.dropFirst("codex mcp remove -- ".count))
            let result = DiagnosticCommand.run("/usr/bin/printf '%s' " + arguments, directory: directory)
            XCTAssertEqual(result.output, name)
            return result
        }
        XCTAssertNil(error)
    }

    func testDisconnectErrorsDoNotExposeCLIOutput() {
        for result in [DiagnosticCommand.Result(error: "secret", exitCode: 1),
                       .init(failure: "secret")] {
            let error = ProviderProbe.disconnect("docs", from: .claude, directory: "/tmp") { _, _ in result }
            XCTAssertNotNil(error)
            XCTAssertFalse(error?.contains("secret") ?? true)
        }
    }

    func testClaudeAccountConnectorsUseExternalManagement() {
        let output = "claude.ai Slack: ✔ Connected\nlocal: ✔ Connected"
        let checks = ProviderProbe.servers(.claude, result: .init(output: output))
        XCTAssertTrue(checks[0].isClaudeAIConnector)
        XCTAssertFalse(checks[1].isClaudeAIConnector)
        let codex = ProviderProbe.servers(.codex, result: .init(output: "[{\"name\":\"claude.ai Slack\"}]"))
        XCTAssertFalse(codex[0].isClaudeAIConnector)
    }

    func testOnlyServerChecksOfferDisconnect() {
        let codex = ProviderProbe.servers(.codex, result: .init(output: "[{\"name\":\"docs\"}]"))
        let claude = ProviderProbe.servers(.claude, result: .init(output: "docs: ✔ Connected"))
        XCTAssertEqual(codex.first?.serverName, "docs")
        XCTAssertEqual(claude.first?.serverName, "docs")
        for agent in AgentKind.allCases {
            XCTAssertNil(ProviderProbe.authentication(agent, result: .init()).serverName)
            XCTAssertNil(ProviderProbe.servers(agent, result: .init(exitCode: 1)).first?.serverName)
        }
        XCTAssertNil(ProviderProbe.servers(.codex, result: .init(output: "[]")).first?.serverName)
    }

    func testBackgroundCommandsComplete() async {
        await withTaskGroup(of: DiagnosticCommand.Result.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    DiagnosticCommand.run("/usr/bin/printf ready", directory: "/tmp", timeout: 5)
                }
            }
            for await result in group {
                XCTAssertNil(result.failure)
                XCTAssertEqual(result.exitCode, 0)
                XCTAssertEqual(result.output, "ready")
            }
        }
    }

    func testCommandFailureAndTimeout() {
        let failed = DiagnosticCommand.run("/usr/bin/false", directory: "/tmp", timeout: 5)
        XCTAssertNil(failed.failure)
        XCTAssertEqual(failed.exitCode, 1)

        let timedOut = DiagnosticCommand.run("/bin/sleep 10", directory: "/tmp", timeout: 1)
        XCTAssertNotNil(timedOut.failure)
    }

    func testClaudeAuthentication() {
        XCTAssertFalse(ProviderProbe.authentication(.claude, result: .init(output: "{\"loggedIn\":true}")).needsAttention)
        XCTAssertTrue(ProviderProbe.authentication(.claude, result: .init(output: "{\"loggedIn\":false}", exitCode: 1)).needsAttention)
        XCTAssertTrue(ProviderProbe.authentication(.claude, result: .init(output: "invalid")).needsAttention)
    }

    func testCodexAuthenticationDoesNotExposeCredentials() {
        let check = ProviderProbe.authentication(.codex, result: .init(error: "Logged in using API key: secret"))
        XCTAssertFalse(check.needsAttention)
        XCTAssertFalse(check.message.contains("secret"))
        XCTAssertTrue(ProviderProbe.authentication(.codex, result: .init(error: "Not logged in", exitCode: 1)).needsAttention)
    }

    func testCodexServerStates() {
        let output = """
        [{"name":"logged-out","enabled":true,"auth_status":"not_logged_in","token":"secret"},
         {"name":"disabled","enabled":false,"auth_status":"not_logged_in"},
         {"name":"oauth","auth_status":"o_auth"},
         {"name":"local","auth_status":"unsupported"}]
        """
        let checks = ProviderProbe.servers(.codex, result: .init(output: output))
        XCTAssertEqual(checks.filter(\.needsAttention).map(\.id), ["logged-out"])
        XCTAssertEqual(checks[1].message, "Disabled")
        XCTAssertTrue(checks[2].message.contains("connection not checked"))
        XCTAssertTrue(checks[3].message.contains("Authentication not reported"))
        XCTAssertFalse(checks.contains { $0.message.contains("secret") })
    }

    func testClaudeServerFailuresAndAuthentication() {
        let output = """
        Checking MCP server health…
        docs: https://example.com/private?token=secret (HTTP) - ✔ Connected
        login: https://example.com - ⚠ Needs authentication
        broken: https://example.com - ✘ Failed to connect — secret
        pending: ⏸ Pending approval
        """
        let checks = ProviderProbe.servers(.claude, result: .init(output: output))
        XCTAssertEqual(checks.count, 4)
        XCTAssertEqual(checks.filter(\.needsAttention).count, 3)
        XCTAssertEqual(checks[0].message, "Connected")
        XCTAssertFalse(checks.contains { $0.message.contains("secret") || $0.message.contains("https:") })
    }

    func testUnknownFailedAndEmptyChecks() {
        for agent in AgentKind.allCases {
            XCTAssertTrue(ProviderProbe.servers(agent, result: .init(failure: "Timed out"))[0].needsAttention)
            XCTAssertTrue(ProviderProbe.servers(agent, result: .init(exitCode: 127))[0].needsAttention)
            XCTAssertTrue(ProviderProbe.servers(agent, result: .init(output: "unexpected"))[0].needsAttention)
        }
        XCTAssertFalse(ProviderProbe.servers(.codex, result: .init(output: "[]"))[0].needsAttention)
        XCTAssertFalse(ProviderProbe.servers(.claude, result: .init(output: "No MCP servers configured"))[0].needsAttention)
        XCTAssertTrue(DiagnosticCommand.Result(error: "WARNING: broken config").hasWarning)
    }
}
