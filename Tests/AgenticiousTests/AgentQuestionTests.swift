import XCTest
@testable import Agenticious

final class AgentQuestionTests: XCTestCase {
    private let input: [String: Any] = ["questions": [
        ["question": "How should the new epic relate to SK-93?", "header": "Existing work", "multiSelect": false,
         "options": [["label": "New umbrella epic", "description": "Move SK-4667–SK-4680 under it"], ["label": "Reuse SK-93"]]],
        ["question": "Which areas are in scope?", "header": "Scope", "multiSelect": true,
         "options": [["label": "Jobs"], ["label": "Mailers"], ["label": "Cron"]]],
    ]]

    func testQuestionsParseWithHeadersOptionsAndMultipleChoice() {
        let questions = AgentQuestion.parse(input)
        XCTAssertEqual(questions.map(\.header), ["Existing work", "Scope"])
        XCTAssertEqual(questions[0].options, [.init(label: "New umbrella epic", detail: "Move SK-4667–SK-4680 under it"), .init(label: "Reuse SK-93", detail: "")])
        XCTAssertEqual(questions.map(\.allowsMultiple), [false, true])
        XCTAssertTrue(AgentQuestion.parse(["questions": [["header": "No text"]]]).isEmpty)
    }

    func testAnswersKeepOptionOrderAndAddOtherText() {
        let scope = AgentQuestion.parse(input)[1]
        XCTAssertEqual(scope.answer(choosing: ["Cron", "Jobs"], other: ""), "Jobs, Cron")
        XCTAssertEqual(scope.answer(choosing: ["Mailers"], other: "  Webhooks "), "Mailers, Webhooks")
        XCTAssertEqual(scope.answer(choosing: [], other: " "), "")
    }

    func testHookReplyAllowsTheCallWithAnswersFilledIn() throws {
        let data = try XCTUnwrap(PendingQuestion.hookReply(input: input, answers: ["Which areas are in scope?": "Jobs"]))
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let output = try XCTUnwrap(reply["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual((updated["questions"] as? [Any])?.count, 2)
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which areas are in scope?": "Jobs"])
    }

    @MainActor
    func testInlineRepliesOnlyWhereTheTerminalWaitsForText() throws {
        let session = AgentSession(task: "Discovery", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        session.status = .yourTurn
        XCTAssertFalse(session.canReplyInline, "no terminal to type into")

        // Never shown: only something to type into.
        session.terminalView = AgentTerminalView(frame: .zero)
        XCTAssertTrue(session.canReplyInline)
        session.status = .needsYou("Which branch?")
        XCTAssertTrue(session.canReplyInline, "asked through need_human, the agent sits at its prompt")

        // Return typed into a permission menu picks Yes, so no reply box wherever one may be up.
        let id = PermissionInterpreter.hold(["tool_name": "Bash", "tool_input": ["command": "touch build/ready"]], in: session) { _ in }
        XCTAssertFalse(session.canReplyInline, "a card is held, and Claude's own menu is open beside it")
        PermissionInterpreter.hookClosed(try XCTUnwrap(id), in: session)
        XCTAssertFalse(session.canReplyInline, "the hook hung up, which doesn't prove the menu closed")
        session.isAwaitingPermission = false
        session.status = .permissionRequired("Run command · touch build/ready · answer in the terminal")
        XCTAssertFalse(session.canReplyInline, "handed to the terminal")
        session.status = .yourTurn
        XCTAssertTrue(session.canReplyInline)
        PermissionInterpreter.hold(["tool_name": "Bash", "tool_input": ["command": "ls"], "agent_id": "a1"], in: session) { _ in }
        XCTAssertFalse(session.canReplyInline, "a subagent's request is held too")
    }
}
