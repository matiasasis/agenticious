import XCTest
@testable import Agenticious

final class EventInterpreterTests: XCTestCase {
    @MainActor
    private func session() -> AgentSession {
        let session = AgentSession(task: "Watch CI and merge", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.planSource = .agent
        session.chunks = [Chunk(id: 1, title: "Resolve conflicts", status: .done), Chunk(id: 2, title: "CI green and merge", status: .inProgress)]
        session.status = .working
        return session
    }

    private var backgroundStop: [String: Any] {
        ["background_tasks": [["id": "ci-watcher", "type": "shell", "status": "running", "description": "Watch CI"]], "session_crons": []]
    }

    @MainActor
    func testBackgroundCIWaitDoesNotAskForHumanOrNudge() async {
        let session = session()
        XCTAssertNil(EventInterpreter.stopHookReply(backgroundStop, for: session))
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        XCTAssertEqual(session.status, .waiting)
        XCTAssertFalse(session.status.needsAttention)
        EventInterpreter.apply("Notification", ["notification_type": "idle_prompt"], to: session)
        XCTAssertEqual(session.status, .waiting)
    }

    @MainActor
    func testScheduledWakeupAlsoWaitsWithoutNudging() async {
        let session = session()
        let payload: [String: Any] = ["background_tasks": [], "session_crons": [["id": "retry-ci", "recurring": false]]]
        XCTAssertNil(EventInterpreter.stopHookReply(payload, for: session))
        EventInterpreter.apply("Stop", payload, to: session)
        XCTAssertEqual(session.status, .waiting)
    }

    @MainActor
    func testWaitingEndsWhenForegroundWorkResumes() async {
        let session = session()
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        EventInterpreter.apply("PreToolUse", ["tool_name": "Bash"], to: session)
        XCTAssertEqual(session.status, .working)
        EventInterpreter.apply("Stop", ["background_tasks": [], "session_crons": [], "stop_hook_active": true], to: session)
        XCTAssertEqual(session.status, .yourTurn)
    }

    @MainActor
    func testExplicitHumanRequestWinsOverBackgroundWork() async {
        let session = session()
        EventInterpreter.apply("mcp", ["tool": "need_human", "args": ["reason": "Approve the merge"]], to: session)
        XCTAssertNil(EventInterpreter.stopHookReply([:], for: session))
        EventInterpreter.apply("PreToolUse", ["tool_name": "mcp__agenticious__update_chunk"], to: session)
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        EventInterpreter.apply("Notification", ["notification_type": "idle_prompt"], to: session)
        XCTAssertEqual(session.status, .needsYou("Approve the merge"))
    }

    @MainActor
    func testPermissionRequestWhileWaitingStillNeedsAttention() async {
        let session = session()
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        EventInterpreter.apply("Notification", ["notification_type": "permission_prompt", "message": "Approve command"], to: session)
        XCTAssertEqual(session.status, .needsYou("Approve command"))
        EventInterpreter.apply("PreToolUse", ["tool_name": "Bash"], to: session)
        XCTAssertEqual(session.status, .working)
    }

    @MainActor
    func testCompletedPlanDoesNotHideBackgroundWorkButExplicitFinishWins() async {
        let session = session()
        session.chunks[1].status = .done
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        XCTAssertEqual(session.status, .waiting)
        EventInterpreter.apply("mcp", ["tool": "finish", "args": ["summary": "Merged"]], to: session)
        EventInterpreter.apply("Stop", backgroundStop, to: session)
        XCTAssertEqual(session.status, .done("Merged"))
    }

    @MainActor
    func testOrdinaryStopsAndCodexNotificationsKeepExistingBehavior() async {
        let session = session()
        XCTAssertNotNil(EventInterpreter.stopHookReply([:], for: session))
        XCTAssertNil(EventInterpreter.stopHookReply(["stop_hook_active": true], for: session))
        EventInterpreter.apply("Stop", [:], to: session)
        XCTAssertEqual(session.status, .yourTurn)
        EventInterpreter.apply("UserPromptSubmit", [:], to: session)
        XCTAssertEqual(session.status, .working)
        EventInterpreter.apply("codex-notify", [:], to: session)
        XCTAssertEqual(session.status, .yourTurn)
        session.chunks[1].status = .done
        EventInterpreter.apply("Stop", ["background_tasks": [], "session_crons": []], to: session)
        XCTAssertEqual(session.status, .done(nil))
    }
}
