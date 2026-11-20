import XCTest
@testable import Agenticious

final class LaunchFailureTests: XCTestCase {
    private let nodenvLines = ["nodenv: claude: command not found", "", "The `claude' command exists in these Node versions:", "  20.18.0"]

    private func diagnosis(_ lines: [String], _ agent: AgentKind = .claude) -> LaunchFailure.Diagnosis? {
        LaunchFailure(code: 127, output: lines, resuming: false).diagnosis(for: agent)
    }

    @MainActor
    private func session(_ agent: AgentKind = .claude) -> AgentSession {
        let session = AgentSession(task: "Fix the build", agent: agent, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        return session
    }

    @MainActor
    func testOnlyAnUnsuccessfulExitBeforeTheCLIShowedCountsAsNotStarted() {
        let fresh = session()
        XCTAssertEqual(fresh.launchFailure(exitCode: 127, output: nodenvLines, resuming: false),
                       LaunchFailure(code: 127, output: nodenvLines, resuming: false))
        XCTAssertNotNil(fresh.launchFailure(exitCode: nil, output: [], resuming: true))
        XCTAssertNil(fresh.launchFailure(exitCode: 0, output: [], resuming: false))
        fresh.cliConfirmed = true
        XCTAssertNil(fresh.launchFailure(exitCode: 127, output: nodenvLines, resuming: false))
    }

    @MainActor
    func testRecordExitKeepsTheFailureOrTheCode() {
        let failed = session()
        let failure = LaunchFailure(code: 127, output: nodenvLines, resuming: false)
        failed.recordExit(127, launchFailure: failure)
        XCTAssertEqual(failed.status, .notStarted(failure))
        XCTAssertFalse(failed.isRunning)
        XCTAssertEqual(failed.status.label, "Didn't start")
        XCTAssertTrue(failed.status.isFinished)
        XCTAssertFalse(failed.status.needsAttention)
        XCTAssertTrue(failed.showsResumeAction)
        let exited = session()
        exited.recordExit(3)
        XCTAssertEqual(exited.status, .exited(3))
    }

    @MainActor
    func testTheSummaryPrefersTheCauseThenTheLastLine() {
        let diagnosed = session()
        diagnosed.recordExit(127, launchFailure: LaunchFailure(code: 127, output: nodenvLines, resuming: false))
        XCTAssertTrue(diagnosed.launchFailureSummary!.hasPrefix("Claude Code isn't installed for the Node version this folder uses."))
        let unknown = session()
        unknown.recordExit(1, launchFailure: LaunchFailure(code: 1, output: ["mise ERROR Tool not installed for shim: claude", "  "], resuming: false))
        XCTAssertEqual(unknown.launchFailureSummary, "mise ERROR Tool not installed for shim: claude")
        let silent = session()
        silent.recordExit(nil, launchFailure: LaunchFailure(code: nil, output: [], resuming: false))
        XCTAssertEqual(silent.launchFailureSummary, "Claude Code ended before it started (no exit code (a signal, or it never ran)).")
        XCTAssertNil(session().launchFailureSummary)
    }

    func testCodeDescriptions() {
        XCTAssertEqual(LaunchFailure(code: 127, output: [], resuming: false).codeDescription, "exit code 127, command not found")
        XCTAssertEqual(LaunchFailure(code: 126, output: [], resuming: false).codeDescription, "exit code 126, could not be run")
        XCTAssertEqual(LaunchFailure(code: 1, output: [], resuming: false).codeDescription, "exit code 1")
    }

    func testNodenvMissingTheCLIForThisVersion() {
        XCTAssertEqual(diagnosis(nodenvLines), LaunchFailure.Diagnosis(
            cause: "Claude Code isn't installed for the Node version this folder uses. It is installed for 20.18.0. Install it in the project folder, so it goes to that version.",
            fix: "npm install -g @anthropic-ai/claude-code"))
        XCTAssertEqual(diagnosis(["nodenv: codex: command not found"], .codex), LaunchFailure.Diagnosis(
            cause: "Codex isn't installed for the Node version this folder uses. Install it in the project folder, so it goes to that version.",
            fix: "npm install -g @openai/codex"))
        XCTAssertEqual(diagnosis(["rbenv: claude: command not found"]),
                       LaunchFailure.Diagnosis(cause: "rbenv found no claude for the version this folder uses.", fix: nil))
    }

    func testNodenvMissingTheVersion() {
        XCTAssertEqual(diagnosis(["nodenv: version `22.1.0' is not installed (set by /path/to/project/.node-version)"]), LaunchFailure.Diagnosis(
            cause: "This folder asks for Node 22.1.0 (set by /path/to/project/.node-version), which nodenv doesn't have.",
            fix: "nodenv install 22.1.0"))
    }

    func testZshCouldNotRunTheCLI() {
        XCTAssertEqual(diagnosis(["zsh:1: command not found: claude"])?.cause,
                       "claude isn't on your login shell's PATH. Install Claude Code, or add its folder to PATH in ~/.zprofile.")
        XCTAssertEqual(diagnosis(["zsh: command not found: codex"], .codex)?.cause,
                       "codex isn't on your login shell's PATH. Install Codex, or add its folder to PATH in ~/.zprofile.")
        XCTAssertEqual(diagnosis(["zsh:1: permission denied: /usr/local/bin/claude"])?.cause, "The claude on your PATH isn't executable.")
        XCTAssertEqual(diagnosis(["zsh:1: /usr/local/bin/claude: bad interpreter: /usr/bin/node: no such file or directory"])?.cause,
                       "The claude on your PATH is a script whose interpreter is missing.")
    }

    func testOtherCommandsAndAgentOutputDoNotMatch() {
        for lines in [["zsh:1: command not found: jq"], ["nodenv: node: command not found"], ["  ⎿  zsh:1: command not found: claude"],
                      ["⏺ Bash(claude)"], ["zsh:1: /usr/local/bin/jq: bad interpreter: /bin/foo: no such file or directory"],
                      ["No version is set for command claude"]] {
            XCTAssertNil(diagnosis(lines), "\(lines)")
        }
        XCTAssertNil(diagnosis(["zsh:1: command not found: claude"], .codex))
    }

    @MainActor
    func testANotStartedStatusSurvivesARestart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let database = try SessionDatabase(url: url)
        let session = AgentSession(task: "Fix the build", agent: .claude, project: .none, directory: folder)
        let failure = LaunchFailure(code: 127, output: nodenvLines, resuming: true)
        session.status = .notStarted(failure)
        try database.save(session)
        XCTAssertEqual(try XCTUnwrap(database.load().first).status, .notStarted(failure))

        try Database(url: url).execute("UPDATE sessions SET status_detail = 'not json'")
        XCTAssertEqual(try XCTUnwrap(SessionDatabase(url: url).load().first).status,
                       .notStarted(LaunchFailure(code: nil, output: [], resuming: false)))
    }
}
