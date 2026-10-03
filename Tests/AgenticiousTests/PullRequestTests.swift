import XCTest
@testable import Agenticious

final class PullRequestTests: XCTestCase {
    func testCanonicalLinksAndUnsafeInputs() {
        XCTAssertEqual(PullRequestReference("https://github.com/team/repo/pull/42/files?token=secret#diff")?.url.absoluteString,
                       "https://github.com/team/repo/pull/42")
        for invalid in ["javascript:alert(1)", "http://github.com/team/repo/pull/42", "https://user:secret@github.com/team/repo/pull/42", "https://github.com/team/repo/issues/42", "https://github.com/team/repo/pull/nope"] {
            XCTAssertNil(PullRequestReference(invalid))
        }
        XCTAssertEqual(PullRequestReference.extract(from: "Review [PR](https://github.com/team/repo/pull/42)." ).first?.label, "team/repo #42")
    }

    @MainActor
    func testReportsAddLinksWithoutChangingStatus() async {
        let session = AgentSession(task: "Review https://github.com/team/repo/pull/42", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.status = .needsYou("Review")
        EventInterpreter.apply("mcp", ["tool": "set_pull_requests", "args": ["urls": ["https://github.com/team/repo/pull/42/files", "https://github.com/team/repo/pull/43", "invalid"]]], to: session)
        XCTAssertEqual(session.pullRequests.count, 2)
        XCTAssertEqual(session.status, .needsYou("Review"))
        EventInterpreter.apply("PostToolUse", ["tool_name": "Bash", "tool_response": ["stdout": "https://github.com/team/repo/pull/44"]], to: session)
        XCTAssertEqual(session.pullRequests.count, 3)
    }

    @MainActor
    func testPersistenceAndLegacyMigration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.sqlite")
        let session = AgentSession(task: "Implement ticket", agent: .claude, project: .none, directory: folder)
        session.recordPullRequests(in: "https://github.com/team/repo/pull/42")
        session.status = .done("Done")
        do {
            let database = try SessionDatabase(url: url)
            try database.save(session)
            let restored = try XCTUnwrap(database.load().first)
            XCTAssertEqual(restored.pullRequests, session.pullRequests)
            try database.save(restored)
            XCTAssertEqual(try database.load().first?.pullRequests.count, 1)
        }
        do {
            let legacy = try Database(url: url)
            try legacy.execute("ALTER TABLE sessions DROP COLUMN pull_requests")
            try legacy.execute("ALTER TABLE sessions DROP COLUMN is_marked_finished")
            try legacy.execute("ALTER TABLE sessions DROP COLUMN task_type")
            try legacy.execute("ALTER TABLE sessions DROP COLUMN cleanup_tasks")
            legacy.schemaVersion = 1
        }
        let migrated = try SessionDatabase(url: url)
        let restored = try XCTUnwrap(migrated.load().first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertTrue(restored.pullRequests.isEmpty)
        restored.recordPullRequests(in: "https://github.com/team/repo/pull/43")
        try migrated.save(restored)
        XCTAssertEqual(try migrated.load().first?.pullRequests.first?.label, "team/repo #43")
    }
}
