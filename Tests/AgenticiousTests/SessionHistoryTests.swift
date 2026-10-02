import XCTest
@testable import Agenticious

final class SessionHistoryTests: XCTestCase {
    @MainActor
    func testOnlyArchivedAgentsAppearNewestFirst() {
        let old = session("Old", startedAt: 1)
        let recent = session("Recent", startedAt: 2)
        let active = session("Active", startedAt: 3)
        active.isMarkedFinished = false
        let result = SessionHistory().results(in: [old, active, recent])
        XCTAssertEqual(result.sessions.map(\.task), ["Recent", "Old"])
        XCTAssertEqual(result.summary, "1–2 of 2 agents")
    }

    @MainActor
    func testSearchMatchesTaskWorkspaceBranchAndProviderAcrossTerms() {
        let archived = session("Repair café login", startedAt: 1)
        archived.worktree = Worktree(repositoryRoot: "/tmp/shop", path: "/tmp/fix", branch: "fix/auth")
        var history = SessionHistory()
        for search in ["CAFE", "shop", "/tmp/shop", "fix/auth", "claude", "Claude Code", " login  SHOP \n"] {
            history.search = search
            XCTAssertEqual(history.results(in: [archived]).total, 1, search)
        }
        history.search = "login missing"
        XCTAssertEqual(history.results(in: [archived]).total, 0)
        history.search = "  \n"
        XCTAssertEqual(history.results(in: [archived]).total, 1)
    }

    @MainActor
    func testPagesHaveNoGapsAndClampAfterResultsDisappear() {
        let sessions = (1...41).map { session("Task \($0)", startedAt: Double($0)) }
        var history = SessionHistory()
        let first = history.results(in: sessions)
        history.page = 2
        let second = history.results(in: sessions)
        history.page = 3
        let last = history.results(in: sessions)
        XCTAssertEqual([first.sessions.count, second.sessions.count, last.sessions.count], [20, 20, 1])
        XCTAssertEqual(last.summary, "41–41 of 41 agents")
        XCTAssertEqual((first.sessions + second.sessions + last.sessions).map(\.id), sessions.reversed().map(\.id))
        XCTAssertEqual(history.results(in: Array(sessions.prefix(20))).number, 1)
        history.page = -1
        XCTAssertEqual(history.results(in: sessions).number, 1)
    }

    @MainActor
    func testSearchResetsPageAndEmptyResultsAreSafe() {
        var history = SessionHistory()
        history.page = 4
        history.search = "missing"
        XCTAssertEqual(history.page, 1)
        let result = history.results(in: [session("Other", startedAt: 1)])
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.summary, "0 agents")
        XCTAssertTrue(SessionHistory().results(in: []).sessions.isEmpty)
    }

    @MainActor
    func testHistoryNavigationPreservesSearchAndQueueGroups() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let archived = session("Saved", startedAt: 1)
        try SessionDatabase(url: url).save(archived)
        let store = SessionStore(databaseURL: url)
        store.history.search = "Saved"
        store.history.page = 2
        store.show(.finished)
        XCTAssertEqual(store.selection, .history)
        store.selection = .session(archived.id)
        XCTAssertTrue(store.visibleSessions.isEmpty)
        XCTAssertTrue(store.visibleProjectGroups.allSatisfy { $0.sessions.isEmpty })
        store.selection = .history
        XCTAssertEqual(store.history.search, "Saved")
        XCTAssertEqual(store.history.page, 2)
        store.show(.queue)
        XCTAssertEqual(store.selection, .overview)
    }

    @MainActor
    private func session(_ task: String, startedAt: TimeInterval) -> AgentSession {
        let session = AgentSession(task: task, agent: .claude, project: Project(path: "/tmp/shop"),
                                   directory: URL(fileURLWithPath: "/tmp/shop"), startedAt: Date(timeIntervalSince1970: startedAt))
        session.isMarkedFinished = true
        return session
    }
}
