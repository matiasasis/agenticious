import XCTest
@testable import Agenticious

final class AgentListTests: XCTestCase {
    func testOnlyCompletedAndExitedSessionsLeaveQueue() {
        for status in [SessionStatus.done(nil), .done("Merged"), .exited(0), .exited(1), .exited(nil)] {
            XCTAssertTrue(AgentList.finished.includes(status))
            XCTAssertFalse(AgentList.queue.includes(status))
        }
        for status in [SessionStatus.starting, .working, .waiting, .yourTurn, .needsYou("Approve"), .interrupted] {
            XCTAssertTrue(AgentList.queue.includes(status))
            XCTAssertFalse(AgentList.finished.includes(status))
        }
    }

    @MainActor
    func testGroupingMovesSessionsWithoutRemovingHistory() async {
        let project = Project(path: "/tmp/project")
        let session = AgentSession(task: "Work", agent: .claude, project: project, directory: URL(fileURLWithPath: "/tmp"))
        let groups = [ProjectGroup(project: project, sessions: [session], isFavorite: true)]
        XCTAssertEqual(AgentList.queue.groups(from: groups)[0].sessions.count, 1)
        XCTAssertTrue(AgentList.finished.groups(from: groups).isEmpty)
        session.status = .done("Finished")
        XCTAssertTrue(AgentList.queue.groups(from: groups)[0].sessions.isEmpty)
        XCTAssertEqual(AgentList.finished.groups(from: groups)[0].sessions.first?.id, session.id)
        session.status = .yourTurn
        XCTAssertEqual(AgentList.queue.groups(from: groups)[0].sessions.first?.id, session.id)
        XCTAssertTrue(AgentList.finished.groups(from: groups).isEmpty)
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
