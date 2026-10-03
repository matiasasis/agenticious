import XCTest
@testable import Agenticious

final class CleanupTaskTests: XCTestCase {
    func testWorkspaceCommandsSkipBlankLinesAndComments() {
        let tasks = CleanupTask.parse("""
            # Stop Rails helpers left in the worktree
            bin/spring stop

              dropdb --if-exists "app_test_$AGENTICIOUS_BRANCH"
            """)
        XCTAssertEqual(tasks.map(\.command), ["bin/spring stop", #"dropdb --if-exists "app_test_$AGENTICIOUS_BRANCH""#])
        XCTAssertEqual(tasks.first?.title, "bin/spring stop")
    }

    func testWorkspaceCommandsAreKeptPerProjectFolder() throws {
        let domain = "CleanupTaskTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let app = Project(path: "/work/app")
        WorkspaceCleanup.setText("bin/spring stop\n", for: app, defaults: defaults)
        XCTAssertEqual(WorkspaceCleanup.tasks(for: app, defaults: defaults).map(\.command), ["bin/spring stop"])
        XCTAssertTrue(WorkspaceCleanup.tasks(for: Project(path: "/work/other"), defaults: defaults).isEmpty)
        XCTAssertTrue(WorkspaceCleanup.tasks(for: .none, defaults: defaults).isEmpty)
        WorkspaceCleanup.setText("  \n", for: app, defaults: defaults)
        XCTAssertEqual(WorkspaceCleanup.text(for: app, defaults: defaults), "")
    }

    @MainActor
    func testAgentsRegisterCleanupThroughTheMCPToolEvenAfterEnding() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        let register: [String: Any] = ["tool": "add_cleanup", "args": ["command": "dropdb --if-exists app_test_sk_1", "title": "Drop test database"]]
        EventInterpreter.apply("mcp", register, to: session)
        EventInterpreter.apply("mcp", ["tool": "add_cleanup", "args": ["command": "  "]], to: session)
        session.status = .ended("Handed off")
        EventInterpreter.apply("mcp", ["tool": "add_cleanup", "args": ["command": "dropdb --if-exists app_test_sk_1", "title": "Drop SK-1 database"]], to: session)
        EventInterpreter.apply("mcp", ["tool": "add_cleanup", "args": ["command": "git worktree remove ../sk-1-review"]], to: session)
        XCTAssertEqual(session.cleanupTasks.map(\.title), ["Drop SK-1 database", "git worktree remove ../sk-1-review"])
    }

    func testRunnerReportsSuccessFailureAndTimeouts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let touch = CleanupTask(command: #"touch "$AGENTICIOUS_BRANCH.done""#)
        XCTAssertEqual(CleanupRunner.run(touch, in: folder, environment: ["AGENTICIOUS_BRANCH": "sk-1"]), .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sk-1.done").path))
        XCTAssertEqual(CleanupRunner.run(CleanupTask(command: "echo first; echo 'database is busy' >&2; exit 3"), in: folder, environment: [:]),
                       .failed("exit 3: database is busy"))
        XCTAssertEqual(CleanupRunner.run(CleanupTask(command: "sleep 5"), in: folder, environment: [:], timeout: 0.3),
                       .failed("still running after 0 seconds, so it was stopped"))
    }

    func testArchiveCleanupRunsTasksInTheWorktreeBeforeRemovingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["init", "--quiet"], ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            git.arguments = ["git", "-C", root.path] + arguments
            git.standardOutput = FileHandle.nullDevice
            git.standardError = FileHandle.nullDevice
            try git.run()
            git.waitUntilExit()
        }
        let worktree = try Worktrees.create(in: root.path, for: "Cleanup tasks")
        let record = root.appendingPathComponent("ran.txt").path
        let tasks = [CleanupTask(command: "pwd > '\(record)'", title: "Record folder"), CleanupTask(command: "echo broken >&2; exit 1", title: "Broken")]
        var steps: [String] = []

        let result = SessionCleanup.run(id: UUID(), processID: nil, worktree: worktree, sharedWorktree: false, tasks: tasks,
                                        directory: URL(fileURLWithPath: worktree.path), supportDirectory: root) { steps.append($0) }

        XCTAssertEqual(steps, ["Stopping the agent…", "Cleaning up: Record folder…", "Cleaning up: Broken…", "Removing its worktree…", "Cleaning up…"])
        XCTAssertEqual(result.completedCleanup, ["pwd > '\(record)'"])
        XCTAssertEqual(result.warnings, ["Cleanup task “Broken” failed (exit 1: broken). It runs again on retry."])
        XCTAssertEqual(try String(contentsOfFile: record, encoding: .utf8).trimmingCharacters(in: .newlines),
                       URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path)
        XCTAssertTrue(result.worktreeRemoved)
    }
}
