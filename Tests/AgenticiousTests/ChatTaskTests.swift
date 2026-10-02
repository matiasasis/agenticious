import AppKit
import XCTest
@testable import Agenticious

final class ChatTaskTests: XCTestCase {
    @MainActor
    private func session() -> AgentSession {
        AgentSession(task: "Chat: What remains?", prompt: "Research the migration", agent: .claude,
                     project: .none, directory: URL(fileURLWithPath: "/tmp"),
                     taskType: TaskType(template: .chat, input: "What remains?"))
    }

    func testChatPromptRequiresAQuestionAndUsesConversationInstructions() throws {
        let prompt = try TaskPrompt(template: .chat, input: "What remains after PR 15103?", notes: "Include dependencies", skillPaths: [])
        XCTAssertEqual(prompt.title, "Chat: What remains after PR 15103?")
        XCTAssertTrue(prompt.instructions.contains("Include dependencies"))
        XCTAssertTrue(prompt.instructions.contains("Read referenced sources"))
        let instructions = ChunkingPrompt.inlined(with: prompt.instructions, isChat: true)
        XCTAssertTrue(instructions.contains("Completing an answer does not end the chat"))
        XCTAssertFalse(instructions.contains("Before any other work, call `set_plan`"))
        XCTAssertThrowsError(try TaskPrompt(template: .chat, input: " ", notes: "", skillPaths: []))
    }

    @MainActor
    func testChatIdentitySurvivesPersistenceAndRenaming() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var template = TaskTemplate.chat
        template.name = "Research together"
        let chat = AgentSession(task: "A different title", agent: .codex, project: .none, directory: folder,
                                taskType: TaskType(template: template, input: "What remains?"))
        let database = try SessionDatabase(url: folder.appendingPathComponent("sessions.sqlite"))
        try database.save(chat)
        XCTAssertTrue(try XCTUnwrap(database.load().first).isChat)
        let old = try JSONDecoder().decode(TaskType.self, from: Data(#"{"name":"Chat","symbol":"sparkles"}"#.utf8))
        XCTAssertFalse(old.isChat)
    }

    @MainActor
    func testSavedPresetsGainChatWithoutOverwritingCustomizations() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var custom = TaskTemplate.custom
        custom.prompt = "My existing prompt: {{input}}"
        try JSONEncoder().encode([custom]).write(to: url)
        let store = TaskPresetStore(url: url)
        XCTAssertEqual(store.preset(id: "custom").prompt, custom.prompt)
        XCTAssertTrue(store.preset(id: "chat").isChat)
        XCTAssertThrowsError(try store.remove(.chat))
        try store.save(store.preset(id: "chat"))
        XCTAssertEqual(TaskPresetStore(url: url).presets.filter(\.isChat).count, 1)
    }

    @MainActor
    func testAnswersAndFinishCallsKeepChatOpenForFollowUps() {
        let chat = session()
        chat.isRunning = true
        chat.status = .working
        XCTAssertTrue(chat.startupSteps.isEmpty)
        XCTAssertNil(EventInterpreter.stopHookReply([:], for: chat))
        chat.chunks = [Chunk(id: 1, title: "Answer", status: .done)]
        for event in ["Stop", "codex-notify"] {
            chat.status = .working
            EventInterpreter.apply(event, [:], to: chat)
            XCTAssertEqual(chat.status, .yourTurn)
        }
        EventInterpreter.apply("mcp", ["tool": "finish", "args": ["summary": "Answer ready"]], to: chat)
        XCTAssertEqual(chat.status, .yourTurn)
        EventInterpreter.apply("UserPromptSubmit", [:], to: chat)
        XCTAssertEqual(chat.status, .working)
        XCTAssertFalse(chat.isMarkedFinished)
        EventInterpreter.apply("mcp", ["tool": "need_human", "args": ["reason": "Which repository?"]], to: chat)
        EventInterpreter.apply("Stop", [:], to: chat)
        XCTAssertEqual(chat.status, .needsYou("Which repository?"))
    }

    @MainActor
    func testEndChatEligibilityProtectsInFlightCleanup() {
        let chat = session()
        XCTAssertTrue(chat.canEndChat)
        chat.backgroundTask = "Starting…"
        XCTAssertFalse(chat.canEndChat)
        chat.backgroundTask = nil
        chat.isArchiving = true
        XCTAssertFalse(chat.canEndChat)
        chat.isArchiving = false
        chat.isMarkedFinished = true
        XCTAssertFalse(chat.canEndChat)
        XCTAssertFalse(AgentSession(task: "Work", agent: .claude, project: .none,
                                    directory: URL(fileURLWithPath: "/tmp")).canEndChat)
    }

    @MainActor
    func testEndChatSavesHistoryWithoutCompletingUnfinishedWork() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("sessions.sqlite")
        let chat = session()
        chat.chunks = [Chunk(id: 1, title: "Open question", status: .pending)]
        let database = try SessionDatabase(url: url)
        try database.save(chat)
        let store = SessionStore(databaseURL: url)
        let saved = try XCTUnwrap(store.sessions.first)
        store.endChat(saved)
        for _ in 0..<100 where saved.isArchiving { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(saved.isArchiving)
        XCTAssertTrue(saved.isMarkedFinished)
        XCTAssertFalse(saved.isRunning)
        XCTAssertEqual(saved.chunks.first?.status, .pending)
        let restored = try XCTUnwrap(database.load().first)
        XCTAssertTrue(restored.isChat)
        XCTAssertTrue(restored.isMarkedFinished)
        XCTAssertEqual(restored.status, .ended("Chat ended by you."))
    }

    func testClaudeConversationIncludesFollowUpsButNotPromptOrToolResults() {
        let lines = [
            #"{"type":"user","uuid":"initial","message":{"role":"user","content":"Research the migration"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Three items remain."}]}}"#,
            #"{"type":"user","uuid":"followup","message":{"role":"user","content":"Which one first?"}}"#,
            #"{"type":"user","uuid":"result","message":{"role":"user","content":[{"type":"tool_result","content":"raw output"}]}}"#,
            #"{"type":"user","uuid":"meta","isMeta":true,"message":{"role":"user","content":"system context"}}"#,
            #"{"type":"user","uuid":"child","isSidechain":true,"message":{"role":"user","content":"subagent input"}}"#
        ]
        let entries = ActivityTranscript.parse(lines: lines, agent: .claude, chatPrompt: "Research the migration")
        XCTAssertEqual(entries.map(\.body), ["Three items remain.", "Which one first?"])
        XCTAssertEqual(entries.map(\.kind), [.message, .userMessage])
        XCTAssertEqual(ActivityTranscript.parse(lines: lines, agent: .claude).count, 1)
    }

    func testCodexConversationExcludesStartupContextAndKeepsUserOrder() {
        let lines = [
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nRules"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Agenticious session ID: abc\nResearch the migration"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"An answer."}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Explain the risks."}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>updated</environment_context>"}]}}"#,
            "{incomplete"
        ]
        let entries = ActivityTranscript.parse(lines: lines, agent: .codex, chatPrompt: "Research the migration")
        XCTAssertEqual(entries.map(\.body), ["An answer.", "Explain the risks."])
        XCTAssertEqual(entries.map(\.kind), [.message, .userMessage])
    }
}
