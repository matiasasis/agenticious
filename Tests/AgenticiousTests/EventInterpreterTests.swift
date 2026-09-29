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
    func testResumedChunkClearsStaleHumanRequest() async {
        let session = session()
        for previous in [SessionStatus.needsYou("Use nine PRs?"), .yourTurn] {
            session.status = previous
            EventInterpreter.apply("mcp", ["tool": "update_chunk", "args": ["index": 2, "status": "in_progress"]], to: session)
            XCTAssertEqual(session.status, .working)
            XCTAssertEqual(session.chunks[1].status, .inProgress)
        }
        EventInterpreter.apply("mcp", ["tool": "need_human", "args": ["reason": "Approve deployment?"]], to: session)
        XCTAssertEqual(session.status, .needsYou("Approve deployment?"))
    }

    @MainActor
    func testBookkeepingAndInvalidChunkUpdatesPreserveHumanRequest() async {
        let session = session()
        session.status = .needsYou("Use nine PRs?")
        for status in ["done", "blocked", "pending", "invalid", ""] {
            EventInterpreter.apply("mcp", ["tool": "update_chunk", "args": ["index": 2, "status": status]], to: session)
            XCTAssertEqual(session.status, .needsYou("Use nine PRs?"))
        }
        EventInterpreter.apply("mcp", ["tool": "update_chunk", "args": ["index": 99, "status": "in_progress"]], to: session)
        XCTAssertEqual(session.status, .needsYou("Use nine PRs?"))
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
    @MainActor
    func testEndingClearsHumanRequestAndPreservesUnfinishedProgress() async {
        let session = session()
        session.status = .needsYou("Who owns this work?")
        let chunks = session.chunks
        EventInterpreter.apply("mcp", ["tool": "end", "args": ["reason": "Left the work to the other session."]], to: session)
        XCTAssertEqual(session.status, .ended("Left the work to the other session."))
        XCTAssertFalse(session.status.needsAttention)
        XCTAssertFalse(session.canMarkFinished)
        XCTAssertEqual(session.chunks, chunks)
        for event in ["Stop", "codex-notify", "PostToolUse", "Notification"] {
            EventInterpreter.apply(event, [:], to: session)
            XCTAssertEqual(session.status, .ended("Left the work to the other session."))
        }
        XCTAssertNil(EventInterpreter.stopHookReply([:], for: session))
        session.recordExit(0)
        XCTAssertEqual(session.status, .ended("Left the work to the other session."))
        EventInterpreter.apply("UserPromptSubmit", [:], to: session)
        XCTAssertEqual(session.status, .working)
    }

    @MainActor
    func testFinalHandoffMessageEndsOlderSessionsWithoutCompletingSteps() async {
        for (event, field) in [("codex-notify", "last-assistant-message"), ("Stop", "last_assistant_message")] {
            let session = session()
            session.status = .needsYou("Should I leave it to the other session?")
            let reason = "Stopped here and left PR #14770 to the other session. No changes or pushes made."
            let payload: [String: Any] = [field: reason]
            XCTAssertNil(EventInterpreter.stopHookReply(payload, for: session))
            EventInterpreter.apply(event, payload, to: session)
            XCTAssertEqual(session.status, .ended(reason))
            XCTAssertEqual(session.completedChunks, 1)
        }
    }

    @MainActor
    func testPausesQuestionsAndQuotedInstructionsDoNotEndWork() async {
        for text in ["Should I stop here and leave it to the other session?", "Stopped here to ask you what to do next.",
                     "The other session asked me to stop a test server. I am continuing the fix.",
                     "If requested, I will stop work and leave it to another session.",
                     "Stopped here until the other session finishes.",
                     "Stopped here and left it to the other session. Should I continue?"] {
            let session = session()
            session.status = .needsYou("What next?")
            EventInterpreter.apply("codex-notify", ["last-assistant-message": text], to: session)
            XCTAssertEqual(session.status, .needsYou("What next?"))
        }
        let session = session()
        EventInterpreter.apply("mcp", ["tool": "end", "args": ["reason": "  "]], to: session)
        XCTAssertEqual(session.status, .working)
    }

    @MainActor
    func testEndedReasonPersistsAcrossRestartAndNewPlanCanRestartWork() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try SessionDatabase(url: folder.appendingPathComponent("test.sqlite"))
        let session = session()
        session.status = .ended("Cancelled by user")
        try database.save(session)
        let restored = try XCTUnwrap(database.load().first)
        XCTAssertEqual(restored.status, session.status)
        XCTAssertEqual(restored.chunks, session.chunks)
        XCTAssertFalse(restored.isMarkedFinished)
        EventInterpreter.apply("mcp", ["tool": "set_plan", "args": ["chunks": ["New work"]]], to: restored)
        XCTAssertEqual(restored.status, .working)
    }

}
