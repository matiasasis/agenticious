import XCTest
@testable import Agenticious

final class SubagentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// A conversation log with a `subagents` folder holding one `.meta.json` per subagent, like Claude Code writes.
    private func conversation(subagents: [(id: String, title: String, toolUse: String)], log: [String]) throws -> URL {
        let transcript = root.appendingPathComponent("conversation.jsonl")
        let folder = root.appendingPathComponent("conversation/subagents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for subagent in subagents {
            try line(["agentType": "general-purpose", "description": subagent.title, "toolUseId": subagent.toolUse])
                .write(to: folder.appendingPathComponent("agent-\(subagent.id).meta.json"), atomically: true, encoding: .utf8)
        }
        try log.joined(separator: "\n").write(to: transcript, atomically: true, encoding: .utf8)
        return transcript
    }

    @MainActor
    func testHooksFollowASubagentFromStartToItsAnswer() throws {
        let transcript = try conversation(subagents: [("a1", "Implement SK-4832", "toolu_1")], log: [])
        let session = AgentSession(task: "Implement the epic", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.status = .working
        let base: [String: Any] = ["session_id": "conversation", "transcript_path": transcript.path]

        EventInterpreter.apply("SubagentStart", base.merging(["agent_id": "a1", "agent_type": "general-purpose"]) { $1 }, to: session)
        let started = try XCTUnwrap(session.subagents.first)
        XCTAssertEqual([started.id, started.type, started.title, started.state.label], ["a1", "general-purpose", "Implement SK-4832", "Running"])
        XCTAssertEqual(started.transcript?.path, root.appendingPathComponent("conversation/subagents/agent-a1.jsonl").path)

        let tool: [String: Any] = ["agent_id": "a1", "tool_name": "Bash", "tool_input": ["command": "bin/rspec spec/models\n--fail-fast"]]
        EventInterpreter.apply("PreToolUse", base.merging(tool) { $1 }, to: session)
        XCTAssertEqual(session.subagents.first?.detail, "Run command · bin/rspec spec/models")
        XCTAssertEqual(session.status, .working)

        EventInterpreter.apply("SubagentStop", base.merging(["agent_id": "a1", "last_assistant_message": "\n## Opened PR #15310\nDetails"]) { $1 }, to: session)
        XCTAssertEqual(session.subagents.first?.state, .done)
        XCTAssertEqual(session.subagents.first?.detail, "Opened PR #15310")
        XCTAssertEqual(session.subagents.count, 1)
    }

    @MainActor
    func testSubagentsStopWithTheirAgentsProcess() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.isRunning = true
        EventInterpreter.apply("SubagentStart", ["agent_id": "a1", "agent_type": "Explore"], to: session)
        EventInterpreter.apply("SubagentStart", ["agent_id": "a2", "agent_type": "Explore"], to: session)
        EventInterpreter.apply("SubagentStop", ["agent_id": "a2"], to: session)
        session.recordExit(nil)
        XCTAssertEqual(session.subagents.map(\.state), [.stopped, .done])
    }

    func testDiscoveryReadsHowEachEarlierSubagentEnded() throws {
        let notification = "<task-notification>\n<task-id>bg-done</task-id>\n<tool-use-id>toolu_2</tool-use-id>\n<status>completed</status>\n</task-notification>"
        let log = [
            line(["type": "user", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_1", "content": [["type": "text", "text": "Found 3 files"]]],
                ["type": "tool_result", "tool_use_id": "toolu_2", "content": [["type": "text", "text": "Async agent launched successfully."]]],
                ["type": "tool_result", "tool_use_id": "toolu_3", "content": [["type": "text", "text": "Async agent launched successfully."]]],
            ]]]),
            line(["type": "user", "message": ["role": "user", "content": notification]]),
            "partial{",
        ]
        let transcript = try conversation(subagents: [("fg", "Find specs", "toolu_1"), ("bg-done", "Review PR", "toolu_2"),
                                                      ("bg-cut", "Implement SK-4833", "toolu_3")], log: log)

        let found = Dictionary(uniqueKeysWithValues: SubagentCatalog.discover(conversation: transcript).map { ($0.id, $0) })
        XCTAssertEqual(found["fg"]?.state, .done)
        XCTAssertEqual(found["bg-done"]?.state, .done)
        XCTAssertEqual(found["bg-cut"]?.state, .stopped)
        XCTAssertEqual(found["bg-cut"]?.title, "Implement SK-4833")
        XCTAssertEqual(found["bg-cut"]?.type, "general-purpose")
        XCTAssertEqual(SubagentCatalog.discover(conversation: root.appendingPathComponent("none.jsonl")), [])
    }

    func testConversationLogIsFoundFromTheWorkingDirectory() throws {
        let folder = root.appendingPathComponent("-Users-example-work-project--claude-worktrees-sk-1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "".write(to: folder.appendingPathComponent("c1.jsonl"), atomically: true, encoding: .utf8)
        let directory = "/Users/example/work/project/.claude/worktrees/sk-1"

        XCTAssertEqual(SubagentCatalog.conversationTranscript(conversationID: "c1", directory: directory, projects: root)?.lastPathComponent, "c1.jsonl")
        XCTAssertNil(SubagentCatalog.conversationTranscript(conversationID: "c2", directory: directory, projects: root))
        XCTAssertEqual(SubagentCatalog.conversationTranscript(from: "/p/c1/subagents/agent-a1.jsonl").path, "/p/c1.jsonl")
        XCTAssertEqual(SubagentCatalog.conversationTranscript(from: "/p/c1.jsonl").path, "/p/c1.jsonl")
    }

    @MainActor
    func testLiveNewsWinsOverWhatTheLogsSaid() {
        let session = AgentSession(task: "Work", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/tmp"))
        session.subagents = [Subagent(id: "a1", type: "", state: .running, detail: "Read file · a.rb")]
        session.mergeSubagents([Subagent(id: "a0", type: "Explore", title: "Earlier", state: .done),
                                Subagent(id: "a1", type: "general-purpose", title: "Implement", state: .stopped)])
        XCTAssertEqual(session.subagents.map(\.id), ["a0", "a1"])
        XCTAssertEqual(session.subagents[1].state, .running)
        XCTAssertEqual(session.subagents[1].title, "Implement")
        XCTAssertEqual(session.subagents[1].type, "general-purpose")
    }

    func testASubagentsOwnLogShowsItsSidechainWork() {
        let prompt = line(["isSidechain": true, "uuid": "u1", "type": "user", "message": ["role": "user", "content": "Implement SK-4832"]])
        let call = line(["isSidechain": true, "type": "assistant", "message": ["id": "m1", "role": "assistant", "content": [
            ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/tmp/a.rb"]]]]])
        XCTAssertEqual(ActivityTranscript.parse(lines: [prompt, call], agent: .claude).count, 0)
        let entries = ActivityTranscript.parse(lines: [prompt, call], agent: .claude, chatPrompt: "", isSubagent: true)
        XCTAssertEqual(entries.map(\.kind), [.userMessage, .tool])
        XCTAssertEqual(entries.first?.body, "Implement SK-4832")
    }
}
