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

    private let claudeTrustScreen = """
    Accessing workspace:
    /tmp/agenticious-scratch
    Quick safety check: Is this a project you created or one you trust?
    Claude Code'll be able to read, edit, and execute files here.
    Security guide
    ❯ No, exit
      Yes, I trust this folder
    enter confirm · escape cancel
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
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .codex), .folderTrust(.codex))
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
    }

    func testIgnoresPartialAndClearedPrompts() {
        let host = terminal()
        feed("Trust this folder?", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
        feed("\u{1b}[2J\u{1b}[H" + trustScreen, to: host)
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .codex), .folderTrust(.codex))
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

    func testDetectsClaudeTrustWithANSIWrappingAndSplitOutput() {
        let host = terminal(columns: 40)
        feed("\u{1b}[33mAccessing work", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
        feed("space:\u{1b}[0m\n" + claudeTrustScreen.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), to: host)
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .claude), .folderTrust(.claude))
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .codex))
    }

    func testDetectsClaudeTrustWithRestrictedPermissionsChoice() {
        let host = terminal()
        feed(claudeTrustScreen.replacingOccurrences(of: "No, exit", with: "No, continue without these permissions"), to: host)
        XCTAssertEqual(StartupPrompt.detect(in: host.terminal, agent: .claude), .folderTrust(.claude))
    }

    func testDoesNotMistakeOtherClaudePromptsForFolderTrust() {
        for text in ["Accessing workspace:\nQuick safety check:", "Yes, I trust this folder\nNo, exit",
                     "Managed settings require approval\nYes, I trust these settings\nNo, exit Claude Code"] {
            let host = terminal()
            feed(text, to: host)
            XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
        }
    }

    func testIgnoresClearedClaudePromptAndScrollback() {
        let host = terminal()
        feed(claudeTrustScreen, to: host)
        feed("\u{1b}[2J\u{1b}[HWelcome to Claude Code", to: host)
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
        feed("\u{1b}[2J\u{1b}[H" + claudeTrustScreen, to: host)
        feed(String(repeating: "\nWorking", count: 25), to: host)
        host.terminal.buffer.yDisp = 0
        XCTAssertNil(StartupPrompt.detect(in: host.terminal, agent: .claude))
    }

    @MainActor
    func testClaudeTrustAlertsOnceAndClearsAfterThePromptDisappears() {
        let session = session(agent: .claude)
        let host = terminal()
        feed(claudeTrustScreen, to: host)
        let initial = session.status
        let prompt = StartupPrompt.detect(in: host.terminal, agent: session.agent)
        StartupPromptInterpreter.apply(prompt, to: session)
        XCTAssertEqual(session.status, .needsYou(StartupPrompt.folderTrust(.claude).reason))
        XCTAssertTrue(StartupPrompt.folderTrust(.claude).reason.hasPrefix("Claude Code"))
        XCTAssertEqual(AgentAlert.transition(from: initial, to: session.status), .needsYou)
        let waiting = session.status
        StartupPromptInterpreter.apply(prompt, to: session)
        XCTAssertNil(AgentAlert.transition(from: waiting, to: session.status))
        XCTAssertTrue(session.startupSteps.isEmpty)
        feed("\u{1b}[2J\u{1b}[HWelcome to Claude Code", to: host)
        StartupPromptInterpreter.apply(StartupPrompt.detect(in: host.terminal, agent: session.agent), to: session)
        XCTAssertEqual(session.status, .starting)
        XCTAssertNil(session.startupPrompt)
    }

    @MainActor
    func testClaudeHooksAndExitSupersedeStartupTrust() {
        let session = session(agent: .claude)
        StartupPromptInterpreter.apply(.folderTrust(.claude), to: session)
        EventInterpreter.apply("UserPromptSubmit", [:], to: session)
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.startupPrompt)
        StartupPromptInterpreter.apply(.folderTrust(.claude), to: session)
        XCTAssertEqual(session.status, .working)
        EventInterpreter.apply("Notification", ["notification_type": "permission_prompt", "message": "Approve command"], to: session)
        StartupPromptInterpreter.apply(nil, to: session)
        XCTAssertEqual(session.status, .needsYou("Approve command"))
        let exited = self.session(agent: .claude)
        StartupPromptInterpreter.apply(.folderTrust(.claude), to: exited)
        exited.recordExit(1)
        XCTAssertNil(exited.startupPrompt)
        XCTAssertEqual(exited.status, .exited(1))
    }

    @MainActor
    private func session(agent: AgentKind = .codex) -> AgentSession {
        let session = AgentSession(task: "Find an email", agent: agent, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        return session
    }

    @MainActor
    func testRaisesOneAlertAndClearsOnlyWhenPromptIsGone() {
        let session = session()
        let initial = session.status
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: session)
        XCTAssertEqual(session.status, .needsYou(StartupPrompt.folderTrust(.codex).reason))
        XCTAssertEqual(AgentAlert.transition(from: initial, to: session.status), .needsYou)
        XCTAssertTrue(session.startupSteps.isEmpty)
        let waiting = session.status
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: session)
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
            StartupPromptInterpreter.apply(.folderTrust(.codex), to: session)
            session.status = status
            XCTAssertNil(session.startupPrompt)
            StartupPromptInterpreter.apply(.folderTrust(.codex), to: session)
            StartupPromptInterpreter.apply(nil, to: session)
            XCTAssertEqual(session.status, status)
        }
        let stopped = session()
        stopped.isRunning = false
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: stopped)
        XCTAssertNil(stopped.startupPrompt)
        let archiving = session()
        archiving.isArchiving = true
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: archiving)
        XCTAssertNil(archiving.startupPrompt)
    }

    @MainActor
    func testPlanAndExitClearStartupPromptImmediately() {
        let session = session()
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: session)
        EventInterpreter.apply("mcp", ["tool": "set_plan", "args": ["chunks": ["Search email"]]], to: session)
        XCTAssertEqual(session.status, .working)
        XCTAssertNil(session.startupPrompt)
        let exited = self.session()
        StartupPromptInterpreter.apply(.folderTrust(.codex), to: exited)
        exited.recordExit(1)
        XCTAssertNil(exited.startupPrompt)
        XCTAssertEqual(AgentAlert.transition(from: .needsYou(StartupPrompt.folderTrust(.codex).reason), to: exited.status), .failed)
    }
}
