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
    func testInlineRepliesOnlyWhereTheTerminalWaitsForText() {
        let session = AgentSession(task: "Discovery", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        session.status = .yourTurn
        XCTAssertFalse(session.canReplyInline, "no terminal to type into")
    }
}
