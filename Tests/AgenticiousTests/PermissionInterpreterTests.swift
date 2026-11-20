import XCTest
@testable import Agenticious

/// What a held hook was sent: nothing yet, an empty reply (Claude's own menu decides), or a decision.
@MainActor
private final class Hook {
    private(set) var replies: [Data?] = []
    var respond: (Data?) -> Void { { [self] in replies.append($0) } }

    var isWaiting: Bool { replies.isEmpty }
    var wasReleased: Bool { replies.count == 1 && replies[0] == nil }
    var behavior: String? { replies.count == 1 ? PermissionFixture.decision(replies[0])?["behavior"] as? String : nil }
    var decision: [String: Any]? { replies.count == 1 ? PermissionFixture.decision(replies[0]) : nil }
}

@MainActor
final class PermissionInterpreterTests: XCTestCase {
    private typealias Fixture = PermissionFixture
    private let touchCall: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": "touch build/ready", "description": "Mark the build ready"]]

    private let notice: [String: Any] = ["notification_type": "permission_prompt", "message": "Claude needs your permission"]

    private func session(_ agent: AgentKind = .claude) -> AgentSession {
        let session = AgentSession(task: "Tidy the build", agent: agent, project: .none, directory: URL(fileURLWithPath: "/code/app"))
        session.isRunning = true
        session.status = .working
        return session
    }

    /// A hook as the store handles it: held requests first, then the status.
    private func receive(_ event: String, _ payload: [String: Any] = [:], in session: AgentSession) {
        PermissionInterpreter.observe(event, payload, in: session)
        EventInterpreter.apply(event, payload, to: session)
    }

    @discardableResult
    private func hold(_ payload: [String: Any], in session: AgentSession, _ hook: Hook) -> UUID? {
        PermissionInterpreter.hold(payload, in: session, respond: hook.respond)
    }

    func testARequestPastTheLimitIsHandedToTheTerminalAndRecorded() throws {
        let session = session(), hooks = (0..<PermissionInterpreter.limit).map { _ in Hook() }
        for (index, hook) in hooks.enumerated() {
            let call = Fixture.touch.merging(["agent_id": "b\(index)", "agent_type": "general-purpose"]) { $1 }
            XCTAssertNotNil(hold(call, in: session, hook))
        }
        session.status = .yourTurn
        // A subagent's thirteenth: no card, but its menu is up now, so it is listed and keeps the reply box shut.
        let extra = Hook()
        XCTAssertNil(hold(Fixture.touch.merging(["agent_id": "late", "agent_type": "general-purpose"]) { $1 }, in: session, extra))
        XCTAssertTrue(extra.wasReleased)
        XCTAssertEqual(session.terminalMenus.count, 1)
        XCTAssertEqual(session.pendingPermissions.count, PermissionInterpreter.limit)
        for pending in session.pendingPermissions { PermissionInterpreter.decide(.allow, on: pending.id, in: session) }
        XCTAssertFalse(session.canReplyInline, "the thirteenth's menu is still up")

        // The main agent's thirteenth: its wait is stored, and a subagent's progress does not clear it.
        let other = self.session()
        for index in 0..<PermissionInterpreter.limit {
            XCTAssertNotNil(hold(Fixture.touch.merging(["agent_id": "c\(index)", "agent_type": "general-purpose"]) { $1 }, in: other, Hook()))
        }
        let main = Hook()
        XCTAssertNil(hold(Fixture.touch, in: other, main))
        XCTAssertTrue(main.wasReleased)
        guard case .permissionRequired = other.status else { return XCTFail("the main agent's wait is shown: \(other.status)") }
        receive("PostToolUse", touchCall.merging(["tool_use_id": "x9", "agent_id": "c0"]) { $1 }, in: other)
        guard case .permissionRequired = other.status else { return XCTFail("a subagent's progress cleared it: \(other.status)") }
        XCTAssertFalse(other.canReplyInline)
        receive("Stop", in: other)
        XCTAssertFalse(other.status.needsAttention, "the main agent's own turn end settles it: \(other.status)")
    }

    func testARequestIsTiedToTheNewestIdenticalCallNotAStaleOne() {
        let session = session(), hook = Hook()
        let call = touchCall.merging(["agent_id": "a1"]) { $1 }
        // s0 was answered in the terminal unseen and never reported back; the subagent then retries the same call.
        PermissionInterpreter.observe("PreToolUse", call.merging(["tool_use_id": "s0"]) { $1 }, in: session)
        PermissionInterpreter.observe("PreToolUse", call.merging(["tool_use_id": "s1"]) { $1 }, in: session)
        XCTAssertNotNil(hold(Fixture.subagentTouch, in: session, hook))
        XCTAssertEqual(session.pendingPermissions.first?.request.toolUseID, "s1")
    }

    func testAHeldRequestShowsOverTheStatusUnderneathAndAllowSettlesIt() throws {
        let session = session(), hook = Hook()
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t1"]) { $1 }, in: session)
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, hook))
        XCTAssertTrue(hook.isWaiting)
        XCTAssertEqual(session.pendingPermissions.first?.request.toolUseID, "t1", "tied to the PreToolUse just before")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready"))
        XCTAssertEqual(AgentAlert.transition(from: .working, to: session.presentedStatus), .permissionRequired)
        XCTAssertFalse(session.isWorking)
        XCTAssertFalse(session.canReplyInline)

        // Claude's own notice lands six seconds in, while the card is still up.
        EventInterpreter.apply("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"], to: session)
        XCTAssertEqual(session.status, .permissionRequired("Claude needs your permission"))
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready"), "the request says more than the notice")
        XCTAssertTrue(hook.isWaiting)

        XCTAssertTrue(PermissionInterpreter.decide(.allow, on: id, in: session))
        XCTAssertEqual(hook.behavior, "allow")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.presentedStatus, .working)
        XCTAssertFalse(session.isAwaitingPermission)
        XCTAssertTrue(session.pendingPermissions.isEmpty)
    }

    func testADecisionIsSentOnceAndOnlyForARequestStillHeld() throws {
        let session = session(), hook = Hook()
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, hook))
        XCTAssertFalse(PermissionInterpreter.decide(.allow, on: UUID(), in: session), "an id nobody holds")
        XCTAssertTrue(hook.isWaiting)
        XCTAssertTrue(PermissionInterpreter.decide(.deny(note: "use make"), on: id, in: session))
        XCTAssertFalse(PermissionInterpreter.decide(.allow, on: id, in: session), "a second click")
        XCTAssertEqual(hook.behavior, "deny")

        // A card released a moment ago: the click that was on its way finds nothing to answer.
        let released = Hook()
        let stale = try XCTUnwrap(hold(Fixture.touch, in: session, released))
        PermissionInterpreter.observe("Stop", [:], in: session)
        XCTAssertTrue(released.wasReleased)
        XCTAssertFalse(PermissionInterpreter.decide(.allow, on: stale, in: session))
        XCTAssertFalse(PermissionInterpreter.decide(.allowAlways, on: stale, in: session))
        XCTAssertTrue(released.wasReleased, "still only the empty reply")

        // And never across agents.
        let other = self.session(), otherHook = Hook()
        let otherID = try XCTUnwrap(hold(Fixture.touch, in: other, otherHook))
        XCTAssertFalse(PermissionInterpreter.decide(.allow, on: otherID, in: session))
        XCTAssertTrue(otherHook.isWaiting)
    }

    func testAllowAndDoNotAskAgainSendsTheRuleOnlyThroughDecide() throws {
        let session = session(), hook = Hook()
        let id = try XCTUnwrap(hold(Fixture.script, in: session, hook))
        XCTAssertTrue(PermissionInterpreter.decide(.allowAlways, on: id, in: session))
        XCTAssertEqual(hook.behavior, "allow")
        XCTAssertEqual((hook.decision?["updatedPermissions"] as? [[String: Any]])?.count, 1)
    }

    func testDenyAndStopHandsTheTurnBackAndReleasesTheMainAgentsOtherRequests() throws {
        let session = session(), first = Hook(), second = Hook(), subagent = Hook()
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, first))
        hold(Fixture.read, in: session, second)
        hold(Fixture.subagentTouch, in: session, subagent)
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready · 2 more waiting"))

        PermissionInterpreter.decide(.deny(note: ""), on: id, in: session)
        XCTAssertEqual(first.decision?["interrupt"] as? Bool, true)
        XCTAssertTrue(second.wasReleased, "Claude's turn is over: nothing of the main agent's can still be asking")
        XCTAssertTrue(subagent.isWaiting, "a background subagent can")
        XCTAssertEqual(session.status, .yourTurn, "no Stop hook follows an interrupt")
        XCTAssertFalse(session.isAwaitingPermission)
        XCTAssertEqual(session.presentedStatus, .permissionRequired("general-purpose subagent · Run command · touch build/ready"))

        PermissionInterpreter.observe("Stop", [:], in: session)
        XCTAssertTrue(subagent.isWaiting, "the parent's Stop says nothing about its subagents")
        PermissionInterpreter.observe("SubagentStop", ["agent_id": "other"], in: session)
        XCTAssertTrue(subagent.isWaiting)
        PermissionInterpreter.observe("SubagentStop", ["agent_id": "a1"], in: session)
        XCTAssertTrue(subagent.wasReleased)
        XCTAssertEqual(session.presentedStatus, .yourTurn, "back to what was underneath")
    }

    func testDenyWithANoteLetsClaudeCarryOnAndASubagentsAnswerLeavesTheMainAgentAlone() throws {
        let session = session(), hook = Hook(), second = Hook()
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, hook))
        hold(Fixture.read, in: session, second)
        session.isAwaitingPermission = true
        session.status = .permissionRequired("Claude needs your permission")
        PermissionInterpreter.decide(.deny(note: "use make"), on: id, in: session)
        XCTAssertNil(hook.decision?["interrupt"])
        XCTAssertTrue(second.isWaiting)
        XCTAssertEqual(session.status, .permissionRequired("Claude needs your permission"), "another main request is still asking")
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Read file · hosts"))

        let waiting = self.session(), subagent = Hook()
        waiting.status = .waiting
        let subagentID = try XCTUnwrap(hold(Fixture.subagentTouch, in: waiting, subagent))
        PermissionInterpreter.decide(.deny(note: ""), on: subagentID, in: waiting)
        XCTAssertEqual(subagent.behavior, "deny")
        XCTAssertNil(subagent.decision?["interrupt"])
        XCTAssertEqual(waiting.status, .waiting)
        XCTAssertEqual(waiting.presentedStatus, .waiting)
    }

    func testAnswerInTerminalSendsNoDecisionAndKeepsTheReplyBoxClosed() throws {
        let session = session(), hook = Hook(), second = Hook()
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, hook))
        let other = try XCTUnwrap(hold(Fixture.read, in: session, second))
        PermissionInterpreter.handToTerminal([id, other], in: session)
        XCTAssertTrue(hook.wasReleased)
        XCTAssertTrue(second.wasReleased)
        XCTAssertEqual(session.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
        XCTAssertTrue(session.isAwaitingPermission)
        XCTAssertFalse(session.canReplyInline)
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("Run command · touch build/ready"), to: session.status), "the human just clicked")

        // Claude's notice keeps the named request; the tool running clears the wait.
        EventInterpreter.apply("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission"], to: session)
        XCTAssertEqual(session.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
        EventInterpreter.apply("PostToolUse", touchCall, to: session)
        XCTAssertEqual(session.status, .working)
        XCTAssertFalse(session.isAwaitingPermission)

        PermissionInterpreter.handToTerminal([id], in: session)
        XCTAssertEqual(session.status, .working, "nothing held, nothing changes")
    }

    func testAFinishedCallReleasesItsOwnRequestByIDThenByInput() {
        let session = session(), hook = Hook()
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t9"]) { $1 }, in: session)
        hold(Fixture.touch, in: session, hook)
        PermissionInterpreter.observe("PostToolUse", touchCall.merging(["tool_use_id": "other"]) { $1 }, in: session)
        XCTAssertTrue(hook.isWaiting, "the same input from another call")
        // The id decides even when the result reports a different input.
        PermissionInterpreter.observe("PostToolUseFailure", ["tool_name": "Bash", "tool_input": ["command": "false"], "tool_use_id": "t9"], in: session)
        XCTAssertTrue(hook.wasReleased, "the human said Yes in the terminal and the tool ran")
        XCTAssertTrue(session.openToolCalls.isEmpty)

        let twins = self.session(), first = Hook(), second = Hook()
        hold(Fixture.touch, in: twins, first)
        hold(Fixture.touch, in: twins, second)
        PermissionInterpreter.observe("PostToolUse", ["tool_name": "Bash", "tool_use_id": "u",
                                                      "tool_input": ["description": "Mark the build ready", "command": "touch build/ready"]], in: twins)
        XCTAssertTrue(first.wasReleased, "one result ends one request, the oldest")
        XCTAssertTrue(second.isWaiting)
        PermissionInterpreter.observe("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/code/app/a.txt"], "tool_use_id": "v"], in: twins)
        PermissionInterpreter.observe("Notification", ["notification_type": "permission_prompt"], in: twins)
        XCTAssertTrue(second.isWaiting, "another tool starting ends nothing: read-only calls run beside a prompt")
    }

    func testTwoIdenticalCallsClaimDifferentToolUseIDs() {
        let session = session(), first = Hook(), second = Hook()
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t1"]) { $1 }, in: session)
        hold(Fixture.touch, in: session, first)
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t2"]) { $1 }, in: session)
        hold(Fixture.touch, in: session, second)
        XCTAssertEqual(session.pendingPermissions.map(\.request.toolUseID), ["t1", "t2"])
        PermissionInterpreter.observe("PostToolUse", touchCall.merging(["tool_use_id": "t2"]) { $1 }, in: session)
        XCTAssertTrue(first.isWaiting)
        XCTAssertTrue(second.wasReleased)
        // A subagent's identical call is another agent's.
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t3", "agent_id": "a1"]) { $1 }, in: session)
        let subagent = Hook()
        hold(Fixture.subagentTouch, in: session, subagent)
        XCTAssertEqual(session.pendingPermissions.last?.request.toolUseID, "t3")
    }

    func testANewTurnReleasesTheMainAgentsRequestsAndClearsAnAnsweredPrompt() {
        for boundary in ["Stop", "UserPromptSubmit"] {
            let session = session(), hook = Hook(), subagent = Hook()
            PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t1"]) { $1 }, in: session)
            hold(Fixture.touch, in: session, hook)
            hold(Fixture.subagentTouch, in: session, subagent)
            session.isAwaitingPermission = true
            session.status = .permissionRequired("Claude needs your permission")
            PermissionInterpreter.observe(boundary, [:], in: session)
            XCTAssertTrue(hook.wasReleased, boundary)
            XCTAssertTrue(subagent.isWaiting, boundary)
            XCTAssertEqual(session.status, .working, "so the turn's own hook can set what comes next")
            XCTAssertFalse(session.isAwaitingPermission)
            XCTAssertTrue(session.openToolCalls.isEmpty)
            // A subagent's Stop is not the main agent's turn ending.
            hold(Fixture.touch, in: session, Hook())
            PermissionInterpreter.observe(boundary, ["agent_id": "a1"], in: session)
            XCTAssertEqual(session.pendingPermissions.count, 2)
        }
    }

    func testAHookThatHangsUpLeavesTheTerminalAsTheOnlyPlaceToAnswer() throws {
        let session = session(), hook = Hook()
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, hook))
        PermissionInterpreter.hookClosed(id, in: session)
        XCTAssertTrue(hook.isWaiting, "nothing is sent to a hook that is gone")
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        XCTAssertEqual(session.status, .needsYou("The permission prompt closed in the terminal (Run command · touch build/ready). Continue there."))
        XCTAssertTrue(session.isAwaitingPermission, "the menu may still be up: typing a reply could pick Yes")
        XCTAssertFalse(session.canReplyInline)
        XCTAssertNil(AgentAlert.transition(from: .permissionRequired("x"), to: session.status))
        session.status = .working
        PermissionInterpreter.hookClosed(id, in: session)
        XCTAssertEqual(session.status, .working, "a late hang-up is ignored")

        let parent = self.session(), subagent = Hook()
        parent.status = .yourTurn
        let subagentID = try XCTUnwrap(hold(Fixture.subagentTouch, in: parent, subagent))
        PermissionInterpreter.hookClosed(subagentID, in: parent)
        XCTAssertEqual(parent.status, .yourTurn, "a subagent's menu shows only after its hook ends, and Claude reports that itself")
        XCTAssertTrue(parent.pendingPermissions.isEmpty)
    }

    func testWhatCannotBeShownOrAnsweredGoesStraightToClaudesOwnMenu() {
        let codex = session(.codex), stopped = session(), archiving = session(), finished = session(), ended = session(), starting = session()
        stopped.isRunning = false
        archiving.isArchiving = true
        finished.isMarkedFinished = true
        ended.status = .ended("Handed off")
        starting.startupPrompt = .folderTrust(.claude)
        for session in [codex, stopped, archiving, finished, ended, starting] {
            let hook = Hook()
            XCTAssertNil(hold(Fixture.touch, in: session, hook))
            XCTAssertTrue(hook.wasReleased)
            XCTAssertTrue(session.pendingPermissions.isEmpty)
        }
        for payload: [String: Any] in [["tool_name": "ExitPlanMode", "tool_input": ["plan": "Do it"]], ["tool_name": "Bash"], [:]] {
            let hook = Hook()
            XCTAssertNil(hold(payload, in: session(), hook))
            XCTAssertTrue(hook.wasReleased)
        }
    }

    func testTheThirteenthRequestIsNotHeldAndEndingTheWorkReleasesEverything() {
        let session = session()
        let hooks = (0..<13).map { _ in Hook() }
        hooks.forEach { hold(Fixture.touch, in: session, $0) }
        XCTAssertEqual(session.pendingPermissions.count, PermissionInterpreter.limit)
        XCTAssertTrue(hooks[..<12].allSatisfy(\.isWaiting))
        XCTAssertTrue(hooks[12].wasReleased)
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready · 11 more waiting"))

        session.status = .ended("Handed off")
        XCTAssertTrue(hooks.allSatisfy(\.wasReleased))
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        XCTAssertEqual(session.presentedStatus, .ended("Handed off"))
    }

    func testExitResumeAndReleasingEverythingNeverAnswerForTheHuman() {
        let changes: [(String, (AgentSession) -> Void)] = [
            ("exit", { $0.recordExit(1) }), ("resume", { $0.prepareToResume() }), ("held requests released", { $0.releaseHeldRequests() }),
        ]
        for (name, change) in changes {
            let session = session(), hook = Hook(), subagent = Hook()
            PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t1"]) { $1 }, in: session)
            hold(Fixture.touch, in: session, hook)
            hold(Fixture.subagentTouch, in: session, subagent)
            change(session)
            XCTAssertTrue(hook.wasReleased, name)
            XCTAssertTrue(subagent.wasReleased, name)
            XCTAssertTrue(session.pendingPermissions.isEmpty, name)
            XCTAssertTrue(session.openToolCalls.isEmpty, name)
        }
    }

    func testPresentedStatusFollowsTheQueueOnlyWhileTheAgentRuns() {
        let session = session()
        XCTAssertEqual(session.presentedStatus, .working)
        hold(Fixture.touch, in: session, Hook())
        hold(Fixture.touch, in: session, Hook())
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready · 1 more waiting"))
        session.status = .yourTurn
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready · 1 more waiting"))
        session.isMarkedFinished = true
        XCTAssertEqual(session.presentedStatus, .yourTurn)
        session.isMarkedFinished = false
        session.isRunning = false
        XCTAssertEqual(session.presentedStatus, .yourTurn)
    }

    func testOpenToolCallsAreBoundedAndForgottenAtATurnBoundary() {
        let session = session()
        for index in 0..<70 {
            PermissionInterpreter.observe("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/code/app/\(index)"], "tool_use_id": "t\(index)"], in: session)
        }
        XCTAssertEqual(session.openToolCalls.count, 64)
        XCTAssertEqual(session.openToolCalls.first?.toolUseID, "t6")
        PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "s1", "agent_id": "a1"]) { $1 }, in: session)
        PermissionInterpreter.observe("PostToolUse", ["tool_name": "Read", "tool_use_id": "t69"], in: session)
        XCTAssertEqual(session.openToolCalls.count, 63)
        PermissionInterpreter.observe("Stop", [:], in: session)
        XCTAssertEqual(session.openToolCalls.map(\.toolUseID), ["s1"], "a background subagent's call outlives the parent's turn")
        PermissionInterpreter.observe("PreToolUse", ["tool_name": "Read", "tool_input": [String: Any]()], in: session)
        XCTAssertEqual(session.openToolCalls.count, 1, "no id, nothing to tie")
    }

    /// A call asks once. Whatever takes its request out of the queue, the call must not lend its id to a retry.
    func testARequestThatLeavesTheQueueClosesItsCallSoARetryIsTiedToItsOwn() throws {
        let leaves: [(String, (UUID, AgentSession) -> Void)] = [
            ("deny with note", { PermissionInterpreter.decide(.deny(note: "not yet"), on: $0, in: $1) }),
            ("allow whose result has not arrived", { PermissionInterpreter.decide(.allow, on: $0, in: $1) }),
            ("hand-over", { PermissionInterpreter.handToTerminal([$0], in: $1) }),
            ("hang-up", { PermissionInterpreter.hookClosed($0, in: $1) }),
            ("key in the terminal", { PermissionInterpreter.typedInTerminal(in: $1) }),
        ]
        for (name, leave) in leaves {
            let session = session(), first = Hook(), retry = Hook()
            PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t1"]) { $1 }, in: session)
            leave(try XCTUnwrap(hold(Fixture.touch, in: session, first)), session)
            XCTAssertTrue(session.openToolCalls.isEmpty, name)
            PermissionInterpreter.observe("PreToolUse", touchCall.merging(["tool_use_id": "t2"]) { $1 }, in: session)
            let stale = try XCTUnwrap(hold(Fixture.touch, in: session, retry))
            XCTAssertEqual(session.pendingPermissions.first?.request.toolUseID, "t2", name)
            // Yes in the terminal, where no key was seen: the result is the only sign.
            receive("PostToolUse", touchCall.merging(["tool_use_id": "t2"]) { $1 }, in: session)
            XCTAssertTrue(retry.wasReleased, name)
            XCTAssertTrue(session.pendingPermissions.isEmpty, name)
            XCTAssertEqual(session.presentedStatus, .working, name)
            XCTAssertFalse(PermissionInterpreter.decide(.allowAlways, on: stale, in: session), "\(name): no card is left to click")
        }

        // A subagent's call outlives the parent's turn, so nothing else would ever close it.
        let subagentCall = touchCall.merging(["agent_id": "a1"]) { $1 }
        for (name, leave) in [("deny", { PermissionInterpreter.decide(.deny(note: ""), on: $0, in: $1) }),
                              ("its stop", { PermissionInterpreter.observe("SubagentStop", ["agent_id": "a1"], in: $1) })] as [(String, (UUID, AgentSession) -> Void)] {
            let session = session(), first = Hook(), retry = Hook()
            PermissionInterpreter.observe("PreToolUse", subagentCall.merging(["tool_use_id": "s1"]) { $1 }, in: session)
            leave(try XCTUnwrap(hold(Fixture.subagentTouch, in: session, first)), session)
            PermissionInterpreter.observe("Stop", [:], in: session)
            XCTAssertTrue(session.openToolCalls.isEmpty, name)
            PermissionInterpreter.observe("PreToolUse", subagentCall.merging(["tool_use_id": "s2"]) { $1 }, in: session)
            hold(Fixture.subagentTouch, in: session, retry)
            XCTAssertEqual(session.pendingPermissions.first?.request.toolUseID, "s2", name)
            PermissionInterpreter.observe("PostToolUse", subagentCall.merging(["tool_use_id": "s2"]) { $1 }, in: session)
            XCTAssertTrue(retry.wasReleased, name)
        }
    }

    func testTheMainAgentsTurnEndingSettlesAMenuOfItsOwnLeftToTheTerminal() throws {
        for boundary in ["Stop", "UserPromptSubmit"] {
            let session = session(), hook = Hook()
            PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.touch, in: session, hook))], in: session)
            XCTAssertEqual(session.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
            // Claude's own notice, six seconds in, is about the same menu.
            EventInterpreter.apply("Notification", notice, to: session)
            PermissionInterpreter.observe(boundary, [:], in: session)
            XCTAssertEqual(session.status, .working, "\(boundary): so the turn's own hook can set what comes next")
            XCTAssertFalse(session.isAwaitingPermission, boundary)
            EventInterpreter.apply(boundary, [:], to: session)
            XCTAssertEqual(session.status, boundary == "Stop" ? .yourTurn : .working)

            // The parent's turn says nothing about a subagent's menu.
            let parent = self.session(), subagent = Hook()
            parent.terminalView = AgentTerminalView(frame: .zero)
            PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: parent, subagent))], in: parent)
            PermissionInterpreter.observe(boundary, [:], in: parent)
            XCTAssertEqual(parent.status, .permissionRequired("general-purpose subagent · Run command · touch build/ready · answer in the terminal"), boundary)
            XCTAssertTrue(parent.isAwaitingPermission, boundary)
            EventInterpreter.apply(boundary, [:], to: parent)
            XCTAssertFalse(parent.canReplyInline, boundary)

            // Nor does it settle a wait nobody handed over: Claude's notice may be about a subagent's menu.
            let noticed = self.session()
            EventInterpreter.apply("Notification", notice, to: noticed)
            PermissionInterpreter.observe(boundary, [:], in: noticed)
            XCTAssertEqual(noticed.status, .permissionRequired("Claude needs your permission"), boundary)
            XCTAssertTrue(noticed.isAwaitingPermission, boundary)
        }

        // A hang-up left the terminal as the only place; the turn ending shows the menu is gone from there too.
        let session = session()
        PermissionInterpreter.hookClosed(try XCTUnwrap(hold(Fixture.touch, in: session, Hook())), in: session)
        XCTAssertTrue(session.status.needsAttention)
        receive("Stop", in: session)
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertFalse(session.isAwaitingPermission)

        // A wait that something else has since replaced is not the main agent's to settle.
        let replaced = self.session()
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.touch, in: replaced, Hook()))], in: replaced)
        replaced.status = .needsYou("Sandbox wants network access")
        PermissionInterpreter.observe("Stop", [:], in: replaced)
        XCTAssertEqual(replaced.status, .needsYou("Sandbox wants network access"))
        XCTAssertTrue(replaced.isAwaitingPermission)
    }

    func testAKeyInTheTerminalTakesTheMainAgentsCardsAndLeavesTheStatusToClaude() throws {
        let session = session(), main = Hook(), second = Hook(), subagent = Hook()
        session.terminalView = AgentTerminalView(frame: .zero)
        hold(Fixture.touch, in: session, main)
        hold(Fixture.read, in: session, second)
        hold(Fixture.subagentTouch, in: session, subagent)
        PermissionInterpreter.typedInTerminal(in: session)
        XCTAssertTrue(main.wasReleased, "an empty reply, never a decision")
        XCTAssertTrue(second.wasReleased)
        XCTAssertTrue(subagent.isWaiting, "its menu is not in the terminal while its card is held")
        XCTAssertEqual(session.status, .working, "whether the key answered is unknown: no status is stored")
        XCTAssertFalse(session.isAwaitingPermission)
        XCTAssertNil(session.mainAgentTerminalWait)
        XCTAssertFalse(session.canReplyInline)

        // Yes on a long command: Working for the whole run. No with feedback and a text answer: the turn ends as usual.
        receive("Stop", in: session)
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertTrue(subagent.isWaiting)
        XCTAssertFalse(session.canReplyInline, "the subagent's card still waits")
        PermissionInterpreter.decide(.allow, on: try XCTUnwrap(session.pendingPermissions.first?.id), in: session)
        XCTAssertTrue(session.canReplyInline)

        // The key did not answer and the menu is still up six seconds later: Claude's own notice says so.
        let unanswered = self.session()
        unanswered.terminalView = AgentTerminalView(frame: .zero)
        hold(Fixture.touch, in: unanswered, Hook())
        PermissionInterpreter.typedInTerminal(in: unanswered)
        receive("Notification", notice, in: unanswered)
        XCTAssertEqual(unanswered.status, .permissionRequired("Claude needs your permission"))
        XCTAssertFalse(unanswered.canReplyInline)

        // Underneath a status that opens the reply box, the menu the key may have left up keeps it closed.
        for underneath in [SessionStatus.yourTurn, .needsYou("Which target?")] {
            let idle = self.session()
            idle.terminalView = AgentTerminalView(frame: .zero)
            hold(Fixture.touch, in: idle, Hook())
            idle.status = underneath
            PermissionInterpreter.typedInTerminal(in: idle)
            XCTAssertEqual(idle.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
            XCTAssertFalse(idle.canReplyInline)
            receive("Stop", in: idle)
            XCTAssertEqual(idle.status, .yourTurn, "and the turn ending settles it")
        }

        // Nothing of the main agent's held: a key is just a key.
        let quiet = self.session(), other = Hook()
        hold(Fixture.subagentTouch, in: quiet, other)
        quiet.status = .yourTurn
        PermissionInterpreter.typedInTerminal(in: quiet)
        XCTAssertTrue(other.isWaiting)
        XCTAssertEqual(quiet.status, .yourTurn)
    }

    func testDenyAndStopNeverOpensTheReplyBoxOntoASubagentsMenu() throws {
        let session = session(), subagent = Hook(), main = Hook()
        session.terminalView = AgentTerminalView(frame: .zero)
        let subagentCall = touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }
        receive("PreToolUse", subagentCall, in: session)
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: session, subagent))], in: session)
        let waiting = SessionStatus.permissionRequired("general-purpose subagent · Run command · touch build/ready · answer in the terminal")
        XCTAssertEqual(session.status, waiting)
        XCTAssertNil(session.mainAgentTerminalWait, "a subagent's wait is not the main agent's turn to settle")

        // The main agent's own tool events wipe the stored wait, as they always did.
        receive("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/etc/hosts"], "tool_use_id": "t1"], in: session)
        XCTAssertEqual(session.status, .working)
        let id = try XCTUnwrap(hold(Fixture.read, in: session, main))
        receive("Notification", notice, in: session)

        PermissionInterpreter.decide(.deny(note: ""), on: id, in: session)
        XCTAssertEqual(main.decision?["interrupt"] as? Bool, true)
        XCTAssertTrue(subagent.wasReleased, "only ever the empty reply")
        XCTAssertEqual(session.status, waiting, "the subagent's menu is still in the terminal")
        XCTAssertTrue(session.isAwaitingPermission)
        XCTAssertFalse(session.canReplyInline)

        // Allow, then the turn ending, is the same menu under a different status.
        let allowed = self.session(), other = Hook()
        allowed.terminalView = AgentTerminalView(frame: .zero)
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: allowed, Hook()))], in: allowed)
        receive("PreToolUse", ["tool_name": "Read", "tool_input": ["file_path": "/etc/hosts"], "tool_use_id": "t1"], in: allowed)
        PermissionInterpreter.decide(.allow, on: try XCTUnwrap(hold(Fixture.read, in: allowed, other)), in: allowed)
        receive("Stop", in: allowed)
        XCTAssertEqual(allowed.status, .yourTurn)
        XCTAssertFalse(allowed.canReplyInline, "Your turn, but not into a subagent's menu")

        // Only the subagent itself shows that it got past the menu: its call ran.
        receive("PostToolUse", subagentCall, in: session)
        XCTAssertEqual(session.status, .working)
        receive("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"], in: session)
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertTrue(session.canReplyInline)
    }

    func testOnlyTheSubagentsOwnProgressClearsAMenuItWasHanded() throws {
        func handed() throws -> AgentSession {
            let session = self.session()
            session.terminalView = AgentTerminalView(frame: .zero)
            PermissionInterpreter.observe("PreToolUse", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }, in: session)
            PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: session, Hook()))], in: session)
            session.isAwaitingPermission = false
            session.status = .yourTurn
            return session
        }
        let read: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": "/code/app/a.txt"]]
        let stays: [(String, [String: Any])] = [
            ("Stop", [:]), ("UserPromptSubmit", [:]), ("PreToolUse", read.merging(["tool_use_id": "t1"]) { $1 }),
            ("PostToolUse", read.merging(["tool_use_id": "t1"]) { $1 }), ("Notification", ["notification_type": "idle_prompt"]),
            ("PreToolUse", read.merging(["tool_use_id": "o1", "agent_id": "other"]) { $1 }), ("SubagentStop", ["agent_id": "other"]),
            // Another call of the same subagent's may have been running beside the menu all along, or start beside
            // it: read-only calls of one message run side by side.
            ("PostToolUse", read.merging(["tool_use_id": "s0", "agent_id": "a1"]) { $1 }),
            ("PreToolUse", read.merging(["tool_use_id": "s2", "agent_id": "a1"]) { $1 }),
            ("PostToolUseFailure", read.merging(["tool_use_id": "s0", "agent_id": "a1"]) { $1 }),
            ("Notification", ["agent_id": "a1"]),
        ]
        for (event, payload) in stays {
            let session = try handed()
            PermissionInterpreter.observe(event, payload, in: session)
            XCTAssertEqual(session.terminalMenus.count, 1, "\(event) \(payload)")
            XCTAssertFalse(session.canReplyInline, event)
        }
        let clears: [(String, [String: Any])] = [
            ("PostToolUse", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }),
            ("PostToolUseFailure", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }),
            ("SubagentStop", ["agent_id": "a1"]),
        ]
        for (event, payload) in clears {
            let session = try handed()
            PermissionInterpreter.observe(event, payload, in: session)
            XCTAssertTrue(session.terminalMenus.isEmpty, event)
            XCTAssertTrue(session.canReplyInline, event)
        }
        for (name, change) in [("exit", { $0.recordExit(0) }), ("resume", { $0.prepareToResume() })] as [(String, (AgentSession) -> Void)] {
            let session = try handed()
            change(session)
            XCTAssertTrue(session.terminalMenus.isEmpty, name)
        }
        // Releasing what is held (archiving does, with the process still running) answers no menu in the terminal.
        let archiving = try handed()
        PermissionInterpreter.releaseForArchive(in: archiving)
        XCTAssertFalse(archiving.canReplyInline)
        // A main agent's request handed over is its own menu, which its turn ending settles.
        let session = session()
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.touch, in: session, Hook()))], in: session)
        XCTAssertTrue(session.terminalMenus.isEmpty)
    }

    func testASubagentsToolEventLeavesAWaitItCannotAnswer() throws {
        // The main agent's menu, handed over after Claude's own notice: a background subagent working on proves nothing.
        let session = session()
        session.terminalView = AgentTerminalView(frame: .zero)
        let id = try XCTUnwrap(hold(Fixture.touch, in: session, Hook()))
        receive("Notification", notice, in: session)
        PermissionInterpreter.handToTerminal([id], in: session)
        let waiting = SessionStatus.permissionRequired("Run command · touch build/ready · answer in the terminal")
        let background: [String: Any] = ["tool_name": "Read", "tool_input": ["file_path": "/code/app/a.txt"], "agent_id": "bg", "tool_use_id": "b1"]
        for event in ["PreToolUse", "PostToolUse"] {
            receive(event, background, in: session)
            XCTAssertEqual(session.status, waiting, event)
            XCTAssertTrue(session.isAwaitingPermission, event)
        }
        receive("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"], in: session)
        XCTAssertEqual(session.status, waiting)
        XCTAssertFalse(session.canReplyInline)
        receive("Stop", in: session)
        XCTAssertEqual(session.status, .yourTurn, "the main agent's own turn ending is what answers it")
        XCTAssertTrue(session.canReplyInline)

        // A subagent's menu handed over: a sibling's tool says nothing about it; its own call finishing does.
        let parent = self.session()
        let call = touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }
        receive("PreToolUse", call, in: parent)
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: parent, Hook()))], in: parent)
        let subagentWaiting = SessionStatus.permissionRequired("general-purpose subagent · Run command · touch build/ready · answer in the terminal")
        receive("PreToolUse", background.merging(["agent_id": "other"]) { $1 }, in: parent)
        XCTAssertEqual(parent.status, subagentWaiting)
        XCTAssertTrue(parent.isAwaitingPermission)
        receive("PostToolUse", call, in: parent)
        XCTAssertEqual(parent.status, .working)
        XCTAssertFalse(parent.isAwaitingPermission)
    }

    func testAStoppedSubagentsWaitSettlesAtTheMainAgentsTurnEnd() throws {
        let idle: [String: Any] = ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]
        let subagentWaiting = SessionStatus.permissionRequired("general-purpose subagent · Run command · touch build/ready · answer in the terminal")
        // Handed over, then denied in the terminal, and the subagent ends at once: no call of its finishes.
        func handed(denyingMainCard: Bool) throws -> AgentSession {
            let session = self.session()
            session.terminalView = AgentTerminalView(frame: .zero)
            receive("PreToolUse", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }, in: session)
            PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: session, Hook()))], in: session)
            receive("Notification", notice, in: session)
            if denyingMainCard {
                PermissionInterpreter.decide(.deny(note: ""), on: try XCTUnwrap(hold(Fixture.read, in: session, Hook())), in: session)
            }
            XCTAssertEqual(session.status, subagentWaiting)
            return session
        }
        for denyingMainCard in [false, true] {
            let session = try handed(denyingMainCard: denyingMainCard)
            receive("SubagentStop", ["agent_id": "a1"], in: session)
            XCTAssertTrue(session.terminalMenus.isEmpty)
            XCTAssertEqual(session.status, subagentWaiting, "settled only at the main agent's turn boundary")
            XCTAssertFalse(session.canReplyInline)
            receive("Notification", idle, in: session)
            XCTAssertEqual(session.status, subagentWaiting, "Claude's idle notice is not a turn boundary")
            receive("Stop", ["background_tasks": [[String: Any]]()], in: session)
            XCTAssertEqual(session.status, .yourTurn, "deny and stop first: \(denyingMainCard)")
            XCTAssertTrue(session.canReplyInline)
            XCTAssertNil(session.subagentTerminalWait)
        }
        // While its menu is still listed, the main agent's turn ending leaves the wait.
        let listed = try handed(denyingMainCard: false)
        receive("Stop", ["background_tasks": [[String: Any]]()], in: listed)
        XCTAssertEqual(listed.status, subagentWaiting)
        XCTAssertFalse(listed.canReplyInline)
    }

    func testAMenuWhoseResultClaudeLoggedIsNoLongerListed() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let conversation = folder.appendingPathComponent("conversation.jsonl")
        let log = SubagentCatalog.transcript(of: "a1", conversation: conversation)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        func result(_ id: String) -> String {
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"The user doesn't want to proceed","is_error":true}]}}"# + "\n"
        }
        try (#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"s1","name":"Bash","input":{}}]}}"# + "\n" + result("s0")).write(to: log, atomically: true, encoding: .utf8)

        let session = session(), main = Hook()
        session.terminalView = AgentTerminalView(frame: .zero)
        session.transcriptURL = conversation
        receive("PreToolUse", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }, in: session)
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: session, Hook()))], in: session)
        let menus = session.terminalMenuResults
        XCTAssertEqual(menus.map(\.toolUseID), ["s1"])
        XCTAssertEqual(menus.map(\.transcript), [log])
        XCTAssertFalse(SubagentCatalog.hasToolResult("s1", in: log), "the call's own tool_use, and another call's result, are not its result")

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(result("s1").utf8))
        try handle.close()
        XCTAssertTrue(SubagentCatalog.hasToolResult("s1", in: log))
        session.dropTerminalMenus(Set(menus.map(\.menu)))
        XCTAssertTrue(session.terminalMenus.isEmpty)
        receive("Stop", in: session)
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertTrue(session.canReplyInline)
        PermissionInterpreter.decide(.deny(note: ""), on: try XCTUnwrap(hold(Fixture.read, in: session, main)), in: session)
        XCTAssertEqual(session.status, .yourTurn, "no wait comes back for a menu that is gone")

        // A call never tied to its id, or a log nobody knows, keeps the menu listed.
        let untied = self.session()
        untied.transcriptURL = conversation
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: untied, Hook()))], in: untied)
        XCTAssertTrue(untied.terminalMenuResults.isEmpty)
        let unlogged = self.session()
        receive("PreToolUse", touchCall.merging(["agent_id": "a1", "tool_use_id": "s1"]) { $1 }, in: unlogged)
        PermissionInterpreter.handToTerminal([try XCTUnwrap(hold(Fixture.subagentTouch, in: unlogged, Hook()))], in: unlogged)
        XCTAssertTrue(unlogged.terminalMenuResults.isEmpty)
        XCTAssertFalse(SubagentCatalog.hasToolResult("s1", in: folder.appendingPathComponent("missing.jsonl")))
    }

    func testArchivingRecordsTheMenusItsReleasedCardsLeaveUp() throws {
        // Deny and stop on the main card left Your turn under a subagent's card; archiving releases that card.
        let session = session()
        session.terminalView = AgentTerminalView(frame: .zero)
        hold(Fixture.subagentTouch, in: session, Hook())
        PermissionInterpreter.decide(.deny(note: ""), on: try XCTUnwrap(hold(Fixture.touch, in: session, Hook())), in: session)
        XCTAssertEqual(session.status, .yourTurn)
        let subagent = try XCTUnwrap(session.pendingPermissions.first?.request)
        session.isArchiving = true
        PermissionInterpreter.releaseForArchive(in: session)
        session.isArchiving = false
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        XCTAssertEqual(session.terminalMenus.map(\.id), [subagent.id], "its menu is up in the terminal now")
        XCTAssertFalse(session.canReplyInline, "if the process outlives the archive, the box stays shut")

        // The main agent's card under a status that would open the box: the same rule as a typed key.
        let main = self.session()
        main.terminalView = AgentTerminalView(frame: .zero)
        hold(Fixture.touch, in: main, Hook())
        main.status = .yourTurn
        PermissionInterpreter.releaseForArchive(in: main)
        XCTAssertEqual(main.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
        XCTAssertFalse(main.canReplyInline)
        receive("Stop", in: main)
        XCTAssertEqual(main.status, .yourTurn)
    }
}
