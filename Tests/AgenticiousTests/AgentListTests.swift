import XCTest
@testable import Agenticious

final class AgentListTests: XCTestCase {
    @MainActor
    func testUnfinishedActiveTasksCannotBeMarkedFinished() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.chunks = [Chunk(id: 1, title: "Completed step", status: .done)]
        for isRunning in [false, true] {
            session.isRunning = isRunning
            for status in [SessionStatus.starting, .working, .waiting, .yourTurn, .needsYou("Approve")] {
                session.status = status
                XCTAssertFalse(session.canMarkFinished)
            }
        }
        session.status = .done(nil)
        XCTAssertTrue(session.canMarkFinished)
        session.isMarkedFinished = true
        XCTAssertFalse(session.canMarkFinished)
    }

    @MainActor
    func testStoppedTasksUseArchiveInsteadOfMarkFinished() {
        let session = AgentSession(task: "Work", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.chunks = [Chunk(id: 1, title: "Stuck step", status: .inProgress)]
        for status in [SessionStatus.interrupted, .exited(nil), .exited(0), .exited(1)] {
            session.status = status
            session.isRunning = false
            session.isMarkedFinished = false
            XCTAssertFalse(session.canMarkFinished)
            session.isRunning = true
            XCTAssertFalse(session.canMarkFinished)
            session.isRunning = false
            session.isMarkedFinished = true
            XCTAssertFalse(session.canMarkFinished)
        }
    }

    @MainActor
    func testStoppingAnUnfinishedAgentMakesItResumable() {
        let session = AgentSession(task: "Work", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.status = .working
        session.isRunning = true
        session.chunks = [Chunk(id: 1, title: "Stuck step", status: .inProgress)]
        session.recordExit(nil)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.status, .exited(nil))
        XCTAssertTrue(session.canResume)
        XCTAssertFalse(session.canMarkFinished)
        XCTAssertEqual(session.chunks.first?.status, .inProgress)

        session.status = .done("Already complete")
        session.isRunning = true
        session.recordExit(0)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.status, .done("Already complete"))
    }

    @MainActor
    func testPuttingAwayInterruptedTaskPreservesProgressAndConversation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try SessionDatabase(url: folder.appendingPathComponent("test.sqlite"))
        let session = AgentSession(task: "Work", agent: .codex, project: .none, directory: folder)
        session.status = .interrupted
        session.conversationID = "saved-conversation"
        session.chunks = [Chunk(id: 1, title: "Stuck step", status: .inProgress)]
        session.isMarkedFinished = true
        try database.save(session)

        let restored = try XCTUnwrap(database.load().first)
        XCTAssertTrue(restored.isMarkedFinished)
        XCTAssertEqual(restored.status, .interrupted)
        XCTAssertEqual(restored.chunks, session.chunks)
        XCTAssertEqual(restored.conversationID, session.conversationID)
        XCTAssertTrue(restored.canResume)
        let groups = [ProjectGroup(project: .none, sessions: [restored], isFavorite: false)]
        XCTAssertTrue(AgentList.queue.groups(from: groups)[0].sessions.isEmpty)
        XCTAssertEqual(AgentList.finished.groups(from: groups)[0].sessions.first?.id, session.id)
    }

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
            try legacy.execute("ALTER TABLE sessions DROP COLUMN task_type")
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
