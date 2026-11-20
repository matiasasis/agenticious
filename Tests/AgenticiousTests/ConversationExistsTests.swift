import XCTest
@testable import Agenticious

final class ConversationExistsTests: XCTestCase {
    func testResumeLooksForClaudesOwnLogOfTheConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("-code-app")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        XCTAssertFalse(ActivityTranscript.claudeConversationExists(id, in: root), "paused before Claude ever ran")
        try Data().write(to: project.appendingPathComponent("\(id).jsonl"))
        XCTAssertTrue(ActivityTranscript.claudeConversationExists(id, in: root))
        XCTAssertFalse(ActivityTranscript.claudeConversationExists(nil, in: root))
        XCTAssertFalse(ActivityTranscript.claudeConversationExists(id, in: root.appendingPathComponent("missing")))
    }
}
