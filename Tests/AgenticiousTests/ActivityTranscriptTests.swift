import XCTest
@testable import Agenticious

final class ActivityTranscriptTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func testClaudeToolsMessagesAndErrors() {
        let call = line(["type": "assistant", "cwd": "/tmp/project", "message": ["id": "m1", "role": "assistant", "content": [
            ["type": "text", "text": "Running **tests**"],
            ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "swift test"]]]]])
        let result = line(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "Tests failed"]]]])
        let entries = ActivityTranscript.parse(lines: [call, result, call, "partial{"], agent: .claude)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].body, "Running **tests**")
        XCTAssertEqual(entries[1].state, .failed)
        XCTAssertEqual(entries[1].body, "swift test")
        XCTAssertEqual(entries[1].directory, "/tmp/project")
        XCTAssertEqual(entries[1].output, "Tests failed")
    }

    func testCodexCorrelatesConcurrentToolsAndKeepsUnknownResultsNeutral() {
        let first = line(["type": "response_item", "payload": ["type": "function_call", "call_id": "a", "name": "exec_command", "arguments": "{\"cmd\":\"false\",\"workdir\":\"/tmp\"}"]])
        let second = line(["type": "response_item", "payload": ["type": "custom_tool_call", "call_id": "b", "name": "apply_patch", "input": "patch"]])
        let output = line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "a", "output": "Process exited with code 1\nfailed"]])
        let customOutput = line(["type": "response_item", "payload": ["type": "custom_tool_call_output", "call_id": "b", "output": "Result received"]])
        let reasoning = line(["type": "response_item", "payload": ["type": "reasoning", "summary": "private"]])
        let entries = ActivityTranscript.parse(lines: [first, second, output, customOutput, reasoning], agent: .codex)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].state, .failed)
        XCTAssertEqual(entries[0].directory, "/tmp")
        XCTAssertEqual(entries[1].state, .unknown)
        XCTAssertEqual(entries[1].body, "patch")
    }

    func testCodexMessagesAndSuccessfulStructuredOutput() {
        let lines = [
            line(["type": "response_item", "payload": ["type": "message", "id": "m1", "role": "assistant", "content": [["type": "output_text", "text": "Done"]]]]),
            line(["type": "response_item", "payload": ["type": "function_call", "call_id": "a", "name": "shell", "arguments": "{}"]]),
            line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "a", "output": "{\"metadata\":{\"exit_code\":0},\"output\":\"ok\"}"]])]
        let entries = ActivityTranscript.parse(lines: lines, agent: .codex)
        XCTAssertEqual(entries[0].body, "Done")
        XCTAssertEqual(entries[1].state, .completed)
    }

    func testDiscoveryDoesNotMixSessionsInTheSameWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let marker = "Agenticious session ID: \(id.uuidString)"
        let unrelated = root.appendingPathComponent("unrelated.jsonl")
        try (line(["payload": ["cwd": "/tmp", "id": "other"]]) + "\nOther task").write(to: unrelated, atomically: true, encoding: .utf8)
        XCTAssertNil(ActivityTranscript.locate(root: root, agent: .codex, sessionID: id, conversationID: nil, directory: "/tmp"))
        let subagent = root.appendingPathComponent("child.jsonl")
        try (line(["payload": ["cwd": "/tmp", "id": "child", "parent_thread_id": "parent"]]) + "\n" + marker).write(to: subagent, atomically: true, encoding: .utf8)
        XCTAssertNil(ActivityTranscript.locate(root: root, agent: .codex, sessionID: id, conversationID: nil, directory: "/tmp"))
        let target = root.appendingPathComponent("rollout-target.jsonl")
        try (line(["payload": ["cwd": "/private/tmp", "id": "target"]]) + "\n" + marker).write(to: target, atomically: true, encoding: .utf8)
        XCTAssertEqual(ActivityTranscript.locate(root: root, agent: .codex, sessionID: id, conversationID: nil, directory: "/tmp")?.lastPathComponent, target.lastPathComponent)
        XCTAssertEqual(ActivityTranscript.locate(root: root, agent: .codex, sessionID: UUID(), conversationID: "target", directory: "/tmp")?.lastPathComponent, target.lastPathComponent)
    }

    func testMissingAndTruncatedLogs() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let missing = ActivityTranscript.read(agent: .codex, sessionID: UUID(), conversationID: "missing", directory: "/tmp", cached: url)
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertNotNil(missing.notice)
        let content = line(["type": "response_item", "payload": ["type": "message", "id": "m1", "role": "assistant", "content": [["type": "output_text", "text": "Saved"]]]])
        try (content + "\n{unfinished").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = ActivityTranscript.read(agent: .codex, sessionID: UUID(), conversationID: "test", directory: "/tmp", cached: url)
        XCTAssertEqual(saved.entries.first?.body, "Saved")
    }
}
