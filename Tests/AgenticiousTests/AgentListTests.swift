import XCTest
@testable import Agenticious

final class AgentListTests: XCTestCase {
    @MainActor
    func testStatusChangesDoNotMoveSessions() async {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        let groups = [ProjectGroup(project: .none, sessions: [session], isFavorite: false)]
        for status in [SessionStatus.starting, .working, .waiting, .yourTurn, .needsYou("Approve"), .interrupted, .done("Done"), .exited(0), .exited(1)] {
            session.status = status
            XCTAssertEqual(AgentList.queue.groups(from: groups)[0].sessions.count, 1)
            XCTAssertTrue(AgentList.finished.groups(from: groups).isEmpty)
        }
        session.isMarkedFinished = true
        XCTAssertTrue(AgentList.queue.groups(from: groups)[0].sessions.isEmpty)
        XCTAssertEqual(AgentList.finished.groups(from: groups)[0].sessions.first?.id, session.id)
        session.isMarkedFinished = false
        XCTAssertEqual(AgentList.queue.groups(from: groups)[0].sessions.first?.id, session.id)
    }

    @MainActor
    func testManualChoicePersistsAndLegacyDoneTasksStayQueued() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: folder)
        session.status = .done("Done")
        do {
            let database = try SessionDatabase(url: url)
            try database.save(session)
            XCTAssertFalse(try XCTUnwrap(database.load().first).isMarkedFinished)
            session.isMarkedFinished = true
            try database.save(session)
            XCTAssertTrue(try XCTUnwrap(database.load().first).isMarkedFinished)
        }
        do {
            let legacy = try Database(url: url)
            try legacy.execute("ALTER TABLE sessions DROP COLUMN is_marked_finished")
            legacy.schemaVersion = 2
        }
        let migrated = try SessionDatabase(url: url)
        let restored = try XCTUnwrap(migrated.load().first)
        XCTAssertFalse(restored.isMarkedFinished)
        XCTAssertEqual(restored.status, .done("Done"))
    }

    @MainActor
    func testFinishedHidesEmptyWorkspaces() async {
        let groups = [ProjectGroup(project: Project(path: "/tmp/favorite"), sessions: [], isFavorite: true),
                      ProjectGroup(project: .none, sessions: [], isFavorite: false),
                      ProjectGroup(project: Project(path: "/tmp/old"), sessions: [], isFavorite: false)]
        XCTAssertEqual(AgentList.queue.groups(from: groups).count, 2)
        XCTAssertTrue(AgentList.finished.groups(from: groups).isEmpty)
    }
}
