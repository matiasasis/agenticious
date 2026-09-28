import XCTest
@testable import Agenticious

final class WorkspaceRepositoryTests: XCTestCase {
    @MainActor
    func testDefaultLookupHandlesRepositorySubfoldersAndMissingPaths() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let child = folder.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "init", "--quiet", folder.path]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }.value
        let repository = WorkspaceRepository()
        await repository.check(child.path)
        XCTAssertEqual(repository.root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       folder.resolvingSymlinksInPath().path)
        XCTAssertTrue(repository.isRepository(child.path))
        await repository.check(folder.appendingPathComponent("missing").path)
        XCTAssertNil(repository.root)
        XCTAssertFalse(repository.isChecking)
    }

    @MainActor
    func testReadinessAndNonRepositoryWorkspaces() async {
        let repository = WorkspaceRepository { path in path == "/repo" ? "/repo" : nil }
        XCTAssertTrue(repository.isReady(for: nil))
        XCTAssertFalse(repository.isRepository(nil))
        XCTAssertFalse(repository.isReady(for: "/repo"))
        await repository.check("/repo")
        XCTAssertTrue(repository.isRepository("/repo"))
        XCTAssertFalse(repository.isReady(for: "/other"))
        XCTAssertFalse(repository.isRepository("/other"))
        await repository.check("/other")
        XCTAssertTrue(repository.isReady(for: "/other"))
        XCTAssertFalse(repository.isRepository("/other"))
        await repository.check(nil)
        XCTAssertNil(repository.root)
        XCTAssertFalse(repository.isChecking)
    }

    @MainActor
    func testOlderLookupCannotReplaceNewWorkspace() async {
        var continuation: CheckedContinuation<String?, Never>?
        let repository = WorkspaceRepository { path in
            if path == "/old" { return await withCheckedContinuation { continuation = $0 } }
            return "/new"
        }
        let old = Task { await repository.check("/old") }
        while continuation == nil { await Task.yield() }
        XCTAssertFalse(repository.isReady(for: "/old"))
        await repository.check("/new")
        continuation?.resume(returning: "/old")
        await old.value
        XCTAssertEqual(repository.root, "/new")
        XCTAssertTrue(repository.isRepository("/new"))
        XCTAssertFalse(repository.isRepository("/old"))
    }

    @MainActor
    func testCancelledLookupDoesNotPublishItsResult() async {
        var continuation: CheckedContinuation<String?, Never>?
        let repository = WorkspaceRepository { _ in await withCheckedContinuation { continuation = $0 } }
        let pending = Task { await repository.check("/repo") }
        while continuation == nil { await Task.yield() }
        pending.cancel()
        continuation?.resume(returning: "/repo")
        await pending.value
        XCTAssertNil(repository.root)
        XCTAssertFalse(repository.isRepository("/repo"))
        await repository.check(nil)
        XCTAssertTrue(repository.isReady(for: nil))
    }
}
