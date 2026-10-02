import Foundation

/// A Claude subagent the agent started with its Agent tool. It runs inside the agent's own process, so it has no
/// terminal or controls of its own: pausing or ending the agent stops it too.
struct Subagent: Identifiable, Equatable {
    enum State: Equatable {
        case running, done, failed, stopped

        var label: String {
            switch self {
            case .running: "Running"
            case .done: "Done"
            case .failed: "Failed"
            case .stopped: "Stopped"
            }
        }
    }

    /// Claude's agent id, which also names its log.
    let id: String
    var type: String
    /// The short description the agent gave when it started it.
    var title: String?
    var state: State
    /// What it is doing now, or the first line of its final answer.
    var detail: String?
    var transcript: URL?

    var displayTitle: String { title ?? (type.isEmpty ? "Subagent" : type) }
}

extension AgentSession {
    /// Applies one hook's news about a subagent, adding it the first time it is heard of.
    func updateSubagent(_ id: String, type: String?, transcript: URL?, _ change: (inout Subagent) -> Void) {
        let index = subagents.firstIndex { $0.id == id }
        var subagent = index.map { subagents[$0] } ?? Subagent(id: id, type: "", state: .running)
        if let type, !type.isEmpty { subagent.type = type }
        if let transcript { subagent.transcript = transcript }
        if let conversation = transcriptURL {
            if subagent.transcript == nil { subagent.transcript = SubagentCatalog.transcript(of: id, conversation: conversation) }
            if subagent.title == nil { subagent.title = SubagentCatalog.metadata(of: id, conversation: conversation)?.title }
        }
        change(&subagent)
        if let index { subagents[index] = subagent } else { subagents.append(subagent) }
    }

    /// Adds subagents found in Claude's logs. Anything heard live since is newer, so it wins.
    func mergeSubagents(_ found: [Subagent]) {
        let live = Dictionary(subagents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let merged = found.map { stored in
            guard var current = live[stored.id] else { return stored }
            current.title = current.title ?? stored.title
            current.transcript = current.transcript ?? stored.transcript
            if current.type.isEmpty { current.type = stored.type }
            return current
        }
        let foundIDs = Set(found.map(\.id))
        subagents = merged + subagents.filter { !foundIDs.contains($0.id) }
    }

    /// Subagents live in the agent's process, so they end with it.
    func stopSubagents() {
        for index in subagents.indices where subagents[index].state == .running {
            subagents[index].state = .stopped
        }
    }
}

/// Reads what Claude Code keeps about subagents next to the conversation's log:
/// `<conversation>/subagents/agent-<id>.jsonl` and an `agent-<id>.meta.json` with its type and description.
enum SubagentCatalog {
    struct Metadata: Equatable {
        let type: String?
        let title: String?
        let toolUseID: String?
    }

    static func transcript(of id: String, conversation: URL) -> URL {
        folder(conversation).appendingPathComponent("agent-\(id).jsonl")
    }

    static func metadata(of id: String, conversation: URL) -> Metadata? {
        let url = folder(conversation).appendingPathComponent("agent-\(id).meta.json")
        guard let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Metadata(type: object["agentType"] as? String, title: object["description"] as? String,
                        toolUseID: object["toolUseId"] as? String)
    }

    /// Hooks fired inside a subagent may carry its own log's path; the conversation's log is two folders up.
    static func conversationTranscript(from path: String) -> URL {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        guard folder.lastPathComponent == "subagents" else { return url }
        return folder.deletingLastPathComponent().appendingPathExtension("jsonl")
    }

    /// Claude names a project's log folder after its working directory, with every other character turned into "-".
    static func conversationTranscript(conversationID: String, directory: String, projects: URL = ActivityTranscript.claudeProjects) -> URL? {
        let paths = [directory, URL(fileURLWithPath: directory).resolvingSymlinksInPath().path]
        return paths.lazy.map { path in
            let folder = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
            return projects.appendingPathComponent(folder).appendingPathComponent(conversationID + ".jsonl")
        }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The subagents of an earlier run, oldest first, with how each ended according to the agent's log.
    /// Anything still unresolved was cut off when the agent's process stopped.
    static func discover(conversation: URL) -> [Subagent] {
        let folder = folder(conversation)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let started = files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }.compactMap { file -> (Date, String, Metadata)? in
            let id = String(file.lastPathComponent.dropFirst("agent-".count).dropLast(".meta.json".count))
            guard file.lastPathComponent.hasPrefix("agent-"), !id.isEmpty, let metadata = metadata(of: id, conversation: conversation) else { return nil }
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return (created, id, metadata)
        }.sorted { $0.0 < $1.0 }
        guard !started.isEmpty else { return [] }

        let outcomes = outcomes(in: conversation, toolUses: Dictionary(started.compactMap { _, id, metadata in
            metadata.toolUseID.map { ($0, id) }
        }, uniquingKeysWith: { first, _ in first }))
        return started.map { _, id, metadata in
            Subagent(id: id, type: metadata.type ?? "", title: metadata.title, state: outcomes[id] ?? .stopped,
                     transcript: transcript(of: id, conversation: conversation))
        }
    }

    private static func folder(_ conversation: URL) -> URL {
        conversation.deletingPathExtension().appendingPathComponent("subagents")
    }

    /// A background subagent ends with a `<task-notification>` naming its id; a foreground one with its Agent tool's result.
    private static func outcomes(in conversation: URL, toolUses: [String: String]) -> [String: Subagent.State] {
        guard let data = try? Data(contentsOf: conversation),
              let notification = try? NSRegularExpression(pattern: #"<task-id>([^<]+)</task-id>.*?<status>([^<]+)</status>"#) else { return [:] }
        var outcomes: [String: Subagent.State] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let line = String(line)
            if line.contains("<task-id>") {
                for match in notification.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    guard let id = Range(match.range(at: 1), in: line).map({ String(line[$0]) }),
                          let status = Range(match.range(at: 2), in: line).map({ line[$0] }) else { continue }
                    outcomes[id] = status == "completed" ? .done : status == "failed" ? .failed : .stopped
                }
            }
            guard line.contains("\"tool_result\""),
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in content where block["type"] as? String == "tool_result" {
                guard let id = (block["tool_use_id"] as? String).flatMap({ toolUses[$0] }), outcomes[id] == nil,
                      !resultText(block["content"]).hasPrefix("Async agent launched") else { continue }
                outcomes[id] = block["is_error"] as? Bool == true ? .failed : .done
            }
        }
        return outcomes
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }
}
