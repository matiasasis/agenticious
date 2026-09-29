import XCTest
@testable import Agenticious

final class StartupProgressTests: XCTestCase {
    func testInvocationWaitsForProviderEvidence() {
        var progress = StartupProgress()
        progress.update(from: TranscriptResult(notice: "No log yet"))
        XCTAssertEqual(progress.steps(for: .codex, submitted: false), [
            Chunk(id: 0, title: "Invoking Codex…", status: .inProgress)
        ])
        progress.update(from: TranscriptResult(url: URL(fileURLWithPath: "/tmp/log.jsonl")))
        XCTAssertEqual(progress.steps(for: .codex, submitted: false).map(\.status), [.done, .inProgress])
        XCTAssertEqual(progress.steps(for: .codex, submitted: false).last?.title, "Waiting for plan…")
        XCTAssertEqual(StartupProgress().steps(for: .claude, submitted: true).first?.status, .done)
    }

    func testClaudeReadActivityAdvancesToPlanWaitAfterResult() {
        let call = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"read","name":"Read","input":{"file_path":"/tmp/project/README.md"}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"read","content":"Contents"}]}}"#
        var progress = StartupProgress(hasResponded: true)
        progress.update(from: TranscriptResult(entries: ActivityTranscript.parse(lines: [call], agent: .claude)))
        let running = progress.steps(for: .claude, submitted: true)
        XCTAssertEqual(running[1].title, "Reading README.md…")
        XCTAssertEqual(running.map(\.status), [.done, .inProgress, .pending])
        progress.update(from: TranscriptResult(entries: ActivityTranscript.parse(lines: [call, result], agent: .claude)))
        XCTAssertEqual(progress.steps(for: .claude, submitted: true).map(\.status), [.done, .done, .inProgress])
    }

    func testCodexFailuresRemainVisibleAndUnchangedReadsKeepProgress() {
        let call = #"{"type":"response_item","payload":{"type":"function_call","call_id":"a","name":"exec_command","arguments":"{\"cmd\":\"false\"}"}}"#
        let output = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"a","output":"Process exited with code 1"}}"#
        var progress = StartupProgress(hasResponded: true)
        progress.update(from: TranscriptResult(entries: ActivityTranscript.parse(lines: [call, output], agent: .codex)))
        let previous = progress
        progress.update(from: TranscriptResult(isUnchanged: true))
        XCTAssertEqual(progress, previous)
        XCTAssertEqual(progress.steps(for: .codex, submitted: false)[1].status, .blocked)
    }

    func testOnlyRecentToolsAppearAndMessagesAreNotShownAsSteps() {
        let entries = (0..<5).map { ActivityEntry(id: String($0), kind: .tool, title: "Read", body: "", state: .completed) }
            + [ActivityEntry(id: "message", kind: .message, title: "Claude", body: "Working on it")]
        var progress = StartupProgress(hasResponded: true)
        progress.update(from: TranscriptResult(entries: entries))
        XCTAssertEqual(progress.tools.map(\.id), ["2", "3", "4"])
        XCTAssertEqual(progress.steps(for: .claude, submitted: false).count, 5)
    }

    @MainActor
    func testStartupYieldsToPlansAndInactiveOrBlockedStates() {
        let session = AgentSession(task: "Work", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        XCTAssertFalse(session.startupSteps.isEmpty)
        session.status = .working
        XCTAssertFalse(session.startupSteps.isEmpty)
        session.backgroundTask = "Creating its worktree…"
        XCTAssertTrue(session.startupSteps.isEmpty)
        session.backgroundTask = nil
        for status in [SessionStatus.needsYou("Approve"), .yourTurn, .waiting, .done(nil), .ended("Stopped"), .exited(1), .interrupted] {
            session.status = status
            XCTAssertTrue(session.startupSteps.isEmpty)
        }
        session.status = .working
        session.isRunning = false
        XCTAssertTrue(session.startupSteps.isEmpty)
        session.isRunning = true
        EventInterpreter.apply("mcp", ["tool": "set_plan", "args": ["chunks": ["Inspect code", "Fix it"]]], to: session)
        XCTAssertTrue(session.startupSteps.isEmpty)
        XCTAssertEqual(session.chunks.count, 2)
    }

    func testRunningToolRemainsVisibleAsOtherToolsComplete() {
        let entries = [ActivityEntry(id: "running", kind: .tool, title: "Read", body: "", state: .running)]
            + (0..<5).map { ActivityEntry(id: String($0), kind: .tool, title: "Glob", body: "", state: .completed) }
        var progress = StartupProgress(hasResponded: true)
        progress.update(from: TranscriptResult(entries: entries))
        XCTAssertEqual(progress.tools.map(\.id), ["running", "3", "4"])
        XCTAssertEqual(progress.steps(for: .claude, submitted: true).last?.status, .pending)
    }
}
