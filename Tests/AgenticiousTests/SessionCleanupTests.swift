import XCTest
import Darwin
@testable import Agenticious

final class SessionCleanupTests: XCTestCase {
    func testProcessDiscoveryUsesExactSessionMarkersAndIncludesDescendants() throws {
        let id = UUID()
        let root = try XCTUnwrap(CleanupProcess(line: "100 1 S Mon Sep 28 10:00:00 2026 codex -c mcp_servers.agenticious.env={AGENTICIOUS_SESSION=\"\(id)\"}"))
        let child = try XCTUnwrap(CleanupProcess(line: "101 100 S Mon Sep 28 10:00:00 2026 /bin/sleep 60"))
        let unrelated = try XCTUnwrap(CleanupProcess(line: "102 1 S Mon Sep 28 10:00:00 2026 editor \(id)"))
        XCTAssertTrue(root.belongs(to: id))
        XCTAssertFalse(root.belongs(to: UUID()))
        XCTAssertFalse(unrelated.belongs(to: id))
        XCTAssertEqual(SessionCleanup.descendants(of: [root], in: [root, child, unrelated]).map(\.pid), [100, 101])
        XCTAssertNil(CleanupProcess(line: "103 1 Z Mon Sep 28 10:00:00 2026 dead"))
    }

    func testCleanupKillsAProcessThatIgnoresTermination() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; /bin/sleep 60 & wait"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        Thread.sleep(forTimeInterval: 0.1)
        let result = SessionCleanup.run(id: UUID(), processID: process.processIdentifier, worktree: nil, sharedWorktree: false)
        XCTAssertTrue(result.processesStopped, result.warnings.joined(separator: "; "))
        guard result.processesStopped else { return }
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    func testCleanupRemovesCleanWorktreeAndConfigurationButKeepsBranch() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try Worktrees.create(in: root.path, for: "Cleanup test")
        let id = UUID()
        let configuration = root.appendingPathComponent("Agenticious/sessions/\(id.uuidString)")
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        let result = SessionCleanup.run(id: id, processID: nil, worktree: worktree, sharedWorktree: false, supportDirectory: root)
        XCTAssertTrue(result.processesStopped)
        XCTAssertTrue(result.worktreeRemoved, result.warnings.joined(separator: "; "))
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configuration.path))
        try git(["show-ref", "--verify", "refs/heads/\(worktree.branch)"], in: root)
    }

    func testCleanupPreservesDirtyAndSharedWorktrees() throws {
        let root = try repository()
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = try Worktrees.create(in: root.path, for: "Unfinished work")
        let file = URL(fileURLWithPath: worktree.path).appendingPathComponent("unfinished.txt")
        try "keep me".write(to: file, atomically: true, encoding: .utf8)
        let dirty = SessionCleanup.run(id: UUID(), processID: nil, worktree: worktree, sharedWorktree: false, supportDirectory: root)
        XCTAssertTrue(dirty.processesStopped)
        XCTAssertFalse(dirty.worktreeRemoved)
        XCTAssertFalse(dirty.warnings.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
        try FileManager.default.removeItem(at: file)
        let shared = SessionCleanup.run(id: UUID(), processID: nil, worktree: worktree, sharedWorktree: true, supportDirectory: root)
        XCTAssertFalse(shared.worktreeRemoved)
        XCTAssertFalse(shared.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    }

    private func repository() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "--quiet"], in: root)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "Initial"], in: root)
        return root
    }

    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
