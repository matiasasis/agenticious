import SwiftTerm
import XCTest
@testable import Agenticious

final class StartupPromptTests: XCTestCase {
    private let trustScreen = """
    Folder access
    /tmp/agenticious-scratch
    Trust this folder? Codex can read, edit, and run files here.
    › 1. Trust and continue
      2. Quit
    enter continue · esc quit
    """

    private func terminal(columns: Int = 100) -> HeadlessTerminal {
        HeadlessTerminal(options: TerminalOptions(cols: columns, rows: 20), onEnd: { _ in })
    }

    private func feed(_ text: String, to host: HeadlessTerminal) {
        host.terminal.feed(buffer: Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)[...])
    }

    func testDetectsTrustScreenWithANSIAndSplitOutput() {
        let host = terminal(columns: 40)
        feed("\u{1b}[32mFolder ac", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
        feed("cess\u{1b}[0m\n" + trustScreen.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), to: host)
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .codex), .folderTrust)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
    }

    func testIgnoresPartialAndClearedPrompts() {
        let host = terminal()
        feed("Trust this folder?", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
        feed("\u{1b}[2J\u{1b}[H" + trustScreen, to: host)
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .codex), .folderTrust)
        feed("\u{1b}[2J\u{1b}[HWelcome to Codex", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
    }

    func testIgnoresOldPromptInScrollbackEvenWhenScrolledUp() {
        let host = terminal()
        feed(trustScreen, to: host)
        feed(String(repeating: "\nWorking", count: 25), to: host)
        host.terminal.buffer.yDisp = 0
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
    }

    @MainActor
    private func session() -> AgentSession {
        let session = AgentSession(task: "Find an email", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        return session
    }

    @MainActor
    func testRaisesOneAlertAndClearsOnlyWhenPromptIsGone() {
        let session = session()
        let initial = session.status
        StartupPromptInterpreter.apply(.folderTrust, to: session)
        XCTAssertEqual(session.status, .needsYou(StartupPrompt.folderTrust.reason))
        XCTAssertEqual(AgentAlert.transition(from: initial, to: session.status), .needsYou)
        XCTAssertTrue(session.startupSteps.isEmpty)
        let waiting = session.status
        StartupPromptInterpreter.apply(.folderTrust, to: session)
        XCTAssertNil(AgentAlert.transition(from: waiting, to: session.status))
        StartupPromptInterpreter.apply(nil, to: session)
        XCTAssertEqual(session.status, .starting)
        XCTAssertNil(session.startupPrompt)
        XCTAssertFalse(session.startupSteps.isEmpty)
    }

    @MainActor
    func testPromptDetectionDoesNotOverrideAgentOrLifecycleStates() {
        for status in [SessionStatus.working, .yourTurn, .needsYou("Approve tool"), .waiting, .done(nil), .ended("Stopped"), .exited(1)] {
            let session = session()
            StartupPromptInterpreter.apply(.folderTrust, to: session)
            session.status = status
            XCTAssertNil(session.startupPrompt)
            StartupPromptInterpreter.apply(.folderTrust, to: session)
            StartupPromptInterpreter.apply(nil, to: session)
            XCTAssertEqual(session.status, status)
        }
        let stopped = session()
        stopped.isRunning = false
        StartupPromptInterpreter.apply(.folderTrust, to: stopped)
        XCTAssertNil(stopped.startupPrompt)
        let archiving = session()
        archiving.isArchiving = true
        StartupPromptInterpreter.apply(.folderTrust, to: archiving)
        XCTAssertNil(archiving.startupPrompt)
    }

    @MainActor
    func testPlanAndExitClearStartupPromptImmediately() {
        let session = session()
        StartupPromptInterpreter.apply(.folderTrust, to: session)
        EventInterpreter.apply("mcp", ["tool": "set_plan", "args": ["chunks": ["Search email"]]], to: session)
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.startupPrompt)
        let exited = self.session()
        StartupPromptInterpreter.apply(.folderTrust, to: exited)
        exited.recordExit(1)
        XCTAssertNil(exited.startupPrompt)
        XCTAssertEqual(AgentAlert.transition(from: .needsYou(StartupPrompt.folderTrust.reason), to: exited.status), .failed)
    }
}
