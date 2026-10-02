import XCTest
@testable import Agenticious

final class AgentResumeTests: XCTestCase {
    @MainActor
    func testResumeLaunchSubmitsContinuationToSavedConversationForBothProviders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for agent in AgentKind.allCases {
            let session = AgentSession(task: "Implement the fix", agent: agent, project: .none, directory: folder)
            session.status = .interrupted
            session.conversationID = UUID().uuidString
            session.chunks = [Chunk(id: 1, title: "Finish the fix", status: .inProgress)]
            let spec = try AgentLauncher(port: 47821, supportDirectory: folder).spec(for: session, resuming: true)
            XCTAssertEqual(spec.directory, folder.path)
            XCTAssertTrue(spec.environment.contains("AD_CONVERSATION=\(session.conversationID!)"))
            XCTAssertTrue(spec.environment.contains("AD_RESUME_PROMPT=\(session.resumePrompt!)"))
            let command = try XCTUnwrap(spec.arguments.last)
            XCTAssertTrue(command.contains(agent == .claude ? "exec claude" : "exec codex resume"))
            XCTAssertTrue(command.hasSuffix(agent == .claude
                ? #" --resume "$AD_CONVERSATION" -- "$AD_RESUME_PROMPT""#
                : #" -- "$AD_CONVERSATION" "$AD_RESUME_PROMPT""#))
        }
    }

    @MainActor
    func testChatsCompletedTasksAndUnknownCodexConversationsDoNotRestartWork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        for agent in AgentKind.allCases {
            let chat = AgentSession(task: "Chat", agent: agent, project: .none, directory: folder,
                                    taskType: TaskType(template: .chat, input: "Explain this"))
            let completed = AgentSession(task: "Completed", agent: agent, project: .none, directory: folder)
            completed.status = .done("Complete")
            for session in [chat, completed] {
                session.conversationID = UUID().uuidString
                XCTAssertNil(session.resumePrompt)
                let spec = try AgentLauncher(port: 47821, supportDirectory: folder).spec(for: session, resuming: true)
                XCTAssertFalse(spec.environment.contains { $0.hasPrefix("AD_RESUME_PROMPT=") })
                XCTAssertFalse(spec.arguments.last!.contains(#""$AD_RESUME_PROMPT""#))
                session.prepareToResume()
                XCTAssertEqual(session.status, .yourTurn)
            }
        }
        let unknown = AgentSession(task: "Interrupted", agent: .codex, project: .none, directory: folder)
        let spec = try AgentLauncher(port: 47821).spec(for: unknown, resuming: true)
        XCTAssertNil(unknown.resumePrompt)
        XCTAssertFalse(spec.arguments.last!.contains(#""$AD_CONVERSATION""#))
        XCTAssertFalse(spec.arguments.last!.contains(#""$AD_RESUME_PROMPT""#))
    }

    @MainActor
    func testResumeClearsStaleAttentionAndRetainsPlanUntilProviderReportsProgress() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.conversationID = UUID().uuidString
        let chunks = [Chunk(id: 1, title: "Completed", status: .done), Chunk(id: 2, title: "Remaining", status: .inProgress)]
        session.chunks = chunks
        session.planSource = .agent
        session.isAwaitingPermission = true
        session.isMarkedFinished = true
        session.startupProgress.hasResponded = true
        session.startupPrompt = .folderTrust(.claude)
        session.status = .needsYou(StartupPrompt.folderTrust(.claude).reason)
        session.prepareToResume()
        session.isRunning = true
        XCTAssertEqual(session.status, .starting)
        XCTAssertTrue(session.isWorking)
        XCTAssertFalse(session.canReplyInline)
        XCTAssertFalse(session.isAwaitingPermission)
        XCTAssertFalse(session.isMarkedFinished)
        XCTAssertNil(session.startupPrompt)
        XCTAssertFalse(session.startupProgress.hasResponded)
        XCTAssertEqual(session.chunks, chunks)
        XCTAssertEqual(session.planSource, .agent)

        StartupPromptInterpreter.apply(.folderTrust(.claude), to: session)
        XCTAssertTrue(session.status.needsAttention)
        StartupPromptInterpreter.apply(nil, to: session)
        XCTAssertEqual(session.status, .starting)
        EventInterpreter.apply("UserPromptSubmit", [:], to: session)
        XCTAssertEqual(session.status, .working)
        EventInterpreter.apply("Stop", [:], to: session)
        XCTAssertEqual(session.status, .yourTurn)
    }

    @MainActor
    func testResumeIsUnavailableDuringLaunchCleanupOrAfterWorktreeRemoval() {
        let session = AgentSession(task: "Work", agent: .codex, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(session.canResume)
        session.isRunning = true
        XCTAssertFalse(session.canResume)
        session.isRunning = false
        session.backgroundTask = "Starting…"
        XCTAssertFalse(session.canResume)
        session.backgroundTask = nil
        session.isArchiving = true
        XCTAssertFalse(session.canResume)
        session.isArchiving = false
        session.worktreeRemoved = true
        XCTAssertFalse(session.canResume)
        session.worktreeRemoved = false
        session.directory = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")
        XCTAssertFalse(session.canResume)
    }
}
