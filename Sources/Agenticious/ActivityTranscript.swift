import Foundation

struct ActivityEntry: Identifiable, Equatable {
    enum Kind: String { case message, userMessage, tool }
    enum State: String { case running, completed, failed, unknown }
    let id: String
    let kind: Kind
    var title: String
    var body: String
    var output = ""
    var directory: String?
    var file: String?
    var state: State = .completed

    var displayTitle: String {
        switch title {
        case "Bash", "exec_command", "shell", "shell_command": "Run command"
        case "exec": "Run tool actions"
        case "Read", "read_file": "Read file"
        case "Edit", "Write", "apply_patch": "Edit files"
        case "Glob", "Grep": "Search files"
        case "AskUserQuestion": "Asked you"
        default: title.replacingOccurrences(of: "mcp__", with: "MCP · ").replacingOccurrences(of: "__", with: " · ")
        }
    }
}

struct TranscriptResult {
    var entries: [ActivityEntry] = []
    var url: URL?
    var conversationID: String?
    var notice: String?
    /// The log's size and modification date when read; the same stamp next time means nothing new to parse.
    var stamp: TranscriptStamp?
    var isUnchanged = false
}

struct TranscriptStamp: Equatable {
    let size: Int
    let modified: Date?

    init?(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        self.size = size
        modified = values.contentModificationDate
    }
}

enum ActivityTranscript {
    /// With the `stamp` of the last read and an unchanged log, returns at once without reading it.
    static func read(agent: AgentKind, sessionID: UUID, conversationID: String?, directory: String, cached: URL?,
                     stamp previous: TranscriptStamp? = nil, chatPrompt: String? = nil) -> TranscriptResult {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = agent == .claude
            ? URL(fileURLWithPath: environment["CLAUDE_CONFIG_DIR"] ?? home.appendingPathComponent(".claude").path).appendingPathComponent("projects")
            : URL(fileURLWithPath: environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path).appendingPathComponent("sessions")
        let url = cached ?? locate(root: root, agent: agent, sessionID: sessionID, conversationID: conversationID, directory: directory)
        guard let url else { return TranscriptResult(notice: "Waiting for this session’s activity log. The terminal remains available.") }
        let stamp = TranscriptStamp(url)
        if let stamp, stamp == previous { return TranscriptResult(url: url, stamp: stamp, isUnchanged: true) }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let length = try handle.seekToEnd()
            let start = length > 4_194_304 ? length - 4_194_304 : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if start > 0 { lines.removeFirst() }
            let entries = parse(lines: lines, agent: agent, chatPrompt: chatPrompt).map { entry in
                var entry = entry
                if entry.kind == .tool, entry.directory == nil { entry.directory = directory }
                return entry
            }
            return TranscriptResult(entries: Array(entries.suffix(200)), url: url,
                                    conversationID: conversationID ?? metadataID(url),
                                    notice: start > 0 || entries.count > 200 ? "Showing recent activity. Full history remains in the terminal and provider log." : nil,
                                    stamp: stamp)
        } catch {
            return TranscriptResult(url: url, notice: "Could not read this session’s activity log. Use the terminal or retry.")
        }
    }

    static func locate(root: URL, agent: AgentKind, sessionID: UUID, conversationID: String?, directory: String) -> URL? {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return nil }
        let marker = "Agenticious session ID: \(sessionID.uuidString)"
        for case let url as URL in files {
            guard url.pathExtension == "jsonl" else { continue }
            if let conversationID {
                let name = url.deletingPathExtension().lastPathComponent
                if agent == .claude ? name == conversationID : name.hasSuffix("-" + conversationID) { return url }
            } else if agent == .codex,
                      let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      Date().timeIntervalSince(modified) < 86_400,
                      let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                let data = (try? handle.read(upToCount: 262_144)) ?? Data()
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains(marker),
                      let first = text.components(separatedBy: "\n").first,
                      let object = json(first), let meta = object["payload"] as? [String: Any],
                      let cwd = meta["cwd"] as? String,
                      URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: directory).resolvingSymlinksInPath().path,
                      meta["parent_thread_id"] as? String == nil else { continue }
                return url
            }
        }
        return nil
    }

    private static func metadataID(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: 65_536)) ?? Data(), as: UTF8.self)
        guard let first = text.components(separatedBy: "\n").first,
              let payload = json(first)?["payload"] as? [String: Any] else { return nil }
        return payload["id"] as? String
    }

    static func parse(lines: [String], agent: AgentKind, chatPrompt: String? = nil) -> [ActivityEntry] {
        var entries: [ActivityEntry] = []
        var positions: [String: Int] = [:]
        func append(_ entry: ActivityEntry) {
            if let index = positions[entry.id] {
                var replacement = entry
                if entry.kind == .tool, !entries[index].output.isEmpty {
                    replacement.output = entries[index].output
                    replacement.state = entries[index].state
                }
                entries[index] = replacement
            } else { positions[entry.id] = entries.count; entries.append(entry) }
        }
        func complete(_ id: String, output: String, failed: Bool?) {
            guard let index = positions[id] else { return }
            entries[index].output = bounded(output)
            entries[index].state = failed.map { $0 ? .failed : .completed } ?? .unknown
        }
        for (index, line) in lines.enumerated() {
            guard let object = json(line) else { continue }
            if agent == .claude {
                guard object["isSidechain"] as? Bool != true,
                      let message = object["message"] as? [String: Any] else { continue }
                if message["role"] as? String == "user", object["isMeta"] as? Bool != true,
                   let entry = userMessage(id: object["uuid"] as? String ?? "user-\(index)",
                                           content: message["content"], chatPrompt: chatPrompt) {
                    append(entry)
                }
                guard let content = message["content"] as? [[String: Any]] else { continue }
                for (blockIndex, block) in content.enumerated() {
                    switch block["type"] as? String {
                    case "text" where message["role"] as? String == "assistant":
                        let id = (message["id"] as? String ?? object["uuid"] as? String ?? "line-\(index)") + "-\(object["apiBlockIndex"] as? Int ?? blockIndex)"
                        append(ActivityEntry(id: id, kind: .message, title: "Claude", body: bounded(block["text"] as? String ?? "")))
                    case "tool_use":
                        guard let id = block["id"] as? String else { continue }
                        append(tool(id: id, name: block["name"] as? String ?? "Tool", input: block["input"] as? [String: Any] ?? [:], directory: object["cwd"] as? String))
                    case "tool_result":
                        complete(block["tool_use_id"] as? String ?? "", output: text(block["content"]), failed: block["is_error"] as? Bool ?? false)
                    default: break
                    }
                }
            } else {
                guard object["type"] as? String == "response_item", let item = object["payload"] as? [String: Any] else { continue }
                switch item["type"] as? String {
                case "message" where item["role"] as? String == "user":
                    if let entry = userMessage(id: item["id"] as? String ?? "user-\(index)",
                                               content: item["content"], chatPrompt: chatPrompt) { append(entry) }
                case "message" where item["role"] as? String == "assistant":
                    append(ActivityEntry(id: item["id"] as? String ?? "line-\(index)", kind: .message, title: "Codex", body: bounded(text(item["content"]))))
                case "function_call", "custom_tool_call":
                    guard let id = item["call_id"] as? String else { continue }
                    let arguments = item["arguments"] as? String ?? ""
                    var input = json(arguments) ?? [:]
                    if let custom = item["input"] as? String { input["input"] = custom }
                    append(tool(id: id, name: item["name"] as? String ?? "Tool", input: input, directory: nil))
                case "function_call_output", "custom_tool_call_output":
                    let output = text(item["output"])
                    let parsed = json(output)
                    let code = (parsed?["exit_code"] as? Int) ?? ((parsed?["metadata"] as? [String: Any])?["exit_code"] as? Int)
                    let failed = (code ?? exitCode(in: output)).map { $0 != 0 }
                    complete(item["call_id"] as? String ?? "", output: output, failed: failed)
                default: break
                }
            }
        }
        return entries
    }

    private static func userMessage(id: String, content: Any?, chatPrompt: String?) -> ActivityEntry? {
        guard let chatPrompt else { return nil }
        let body = text(content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, chatPrompt.isEmpty || !body.contains(chatPrompt),
              !body.hasPrefix("Agenticious session ID:"),
              !body.hasPrefix("# AGENTS.md instructions"), !body.hasPrefix("<environment_context>"),
              !body.hasPrefix("<system-reminder>"), !body.hasPrefix("<task-notification>") else { return nil }
        return ActivityEntry(id: id, kind: .userMessage, title: "You", body: bounded(body))
    }

    private static func tool(id: String, name: String, input: [String: Any], directory: String?) -> ActivityEntry {
        let questions = name == "AskUserQuestion" ? AgentQuestion.parse(input) : []
        let body = !questions.isEmpty ? questions.map { question in
            ([question.text] + question.options.map { "  • " + $0.label }).joined(separator: "\n")
        }.joined(separator: "\n\n") : input["command"] as? String ?? input["cmd"] as? String ?? input["code"] as? String ?? input["input"] as? String ?? text(input)
        return ActivityEntry(id: id, kind: .tool, title: name, body: bounded(body),
                             directory: input["workdir"] as? String ?? directory,
                             file: input["file_path"] as? String ?? input["path"] as? String, state: .running)
    }

    private static func bounded(_ text: String) -> String {
        text.count > 32_768 ? String(text.prefix(32_768)) + "\n… Truncated; see the provider log for the full content." : text
    }

    private static func exitCode(in output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(?:Process exited with code|Exit code:)\s*(-?\d+)"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Int(output[range])
    }

    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let blocks = value as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}
