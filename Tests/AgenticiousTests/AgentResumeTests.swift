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
    func testClaudeSettingsHoldPermissionRequestsOpenAndNeverTurnAFailureIntoADecision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: folder)
        _ = try AgentLauncher(port: 47990, supportDirectory: folder).spec(for: session)
        let file = folder.appendingPathComponent("Agenticious/sessions/\(session.id.uuidString)/settings.json")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let hooks = try XCTUnwrap(settings["hooks"] as? [String: [[String: Any]]])

        let entries = try XCTUnwrap(hooks["PermissionRequest"])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0]["matcher"], "every tool; the app filters by name")
        XCTAssertEqual(Set(entries[0].keys), ["hooks"])
        let commands = try XCTUnwrap(entries[0]["hooks"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(Set(commands[0].keys), ["type", "command", "timeout"], "no onFailure: a hook that fails must leave Claude's own menu in charge")
        XCTAssertEqual(commands[0]["type"] as? String, "command")
        XCTAssertEqual(commands[0]["timeout"] as? Int, 86_400)
        XCTAssertEqual(commands[0]["command"] as? String,
                       "curl -s -m 86400 -X POST --data-binary @- 'http://127.0.0.1:47990/hook/\(session.id.uuidString)/PermissionRequest' 2>/dev/null || true",
                       "the reply reaches Claude as the hook's output; an unreachable app is an empty one")

        let failure = try XCTUnwrap(hooks["PostToolUseFailure"]?.first)
        XCTAssertEqual(failure["matcher"] as? String, "*")
        let report = try XCTUnwrap((failure["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(report.hasSuffix("/PostToolUseFailure' >/dev/null 2>&1 || true"), "reported, never read back")
        XCTAssertEqual((hooks["PreToolUse"] ?? []).count, 2, "the question hook is still there")

        // Resuming writes the file again, which is how an agent from an earlier version gets the hook.
        try FileManager.default.removeItem(at: file)
        session.conversationID = UUID().uuidString
        _ = try AgentLauncher(port: 47990, supportDirectory: folder).spec(for: session, resuming: true)
        let resumed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNotNil((resumed["hooks"] as? [String: Any])?["PermissionRequest"])

        let codex = AgentSession(task: "Tidy the build", agent: .codex, project: .none, directory: folder)
        let spec = try AgentLauncher(port: 47990, supportDirectory: folder).spec(for: codex)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Agenticious/sessions/\(codex.id.uuidString)/settings.json").path))
        XCTAssertFalse((spec.arguments + spec.environment).contains { $0.contains("PermissionRequest") || $0.contains("PostToolUseFailure") })
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
    func testCompletedTasksDoNotOfferResume() {
        let session = AgentSession(task: "Complete", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.status = .done("Task complete")
        for isRunning in [false, true] {
            session.isRunning = isRunning
            for archived in [false, true] {
                session.isMarkedFinished = archived
                XCTAssertFalse(session.showsResumeAction)
                XCTAssertFalse(session.canResume)
            }
        }
        session.isRunning = false
        session.isMarkedFinished = false
        for status in [SessionStatus.interrupted, .paused, .exited(nil), .ended("Stopped"), .yourTurn] {
            session.status = status
            XCTAssertTrue(session.showsResumeAction)
            XCTAssertTrue(session.canResume)
        }
    }

    @MainActor
    func testEndIsOfferedOnlyForUnfinishedTasks() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        for status in [SessionStatus.working, .paused, .interrupted, .exited(1), .needsYou("Approve"), .yourTurn] {
            session.status = status
            XCTAssertTrue(session.canEnd)
        }
        for status in [SessionStatus.done(nil), .ended("Handed off")] {
            session.status = status
            XCTAssertFalse(session.canEnd)
        }
        session.status = .paused
        session.isMarkedFinished = true
        XCTAssertFalse(session.canEnd)
        session.isMarkedFinished = false
        session.isArchiving = true
        XCTAssertFalse(session.canEnd)
        XCTAssertFalse(AgentSession(task: "Chat", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"),
                                    taskType: TaskType(template: .chat, input: "Chat")).canEnd)
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
