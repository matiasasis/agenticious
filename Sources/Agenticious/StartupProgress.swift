import Foundation

struct StartupProgress: Equatable {
    var hasResponded = false
    var tools: [ActivityEntry] = []

    mutating func update(from result: TranscriptResult) {
        guard !result.isUnchanged else { return }
        hasResponded = hasResponded || result.url != nil
        let reported = result.entries.filter { $0.kind == .tool }
        let running = reported.filter { $0.state == .running }.suffix(3)
        let recent = reported.filter { $0.state != .running }.suffix(3 - running.count)
        let visibleIDs = Set((Array(running) + recent).map(\.id))
        tools = reported.filter { visibleIDs.contains($0.id) }
    }

    func steps(for agent: AgentKind, submitted: Bool) -> [Chunk] {
        guard hasResponded || submitted else {
            return [Chunk(id: 0, title: "Invoking \(agent.displayName)…", status: .inProgress)]
        }
        var steps = [Chunk(id: 0, title: "\(agent.displayName) started", status: .done)]
        steps += tools.enumerated().map { index, tool in
            Chunk(id: index + 1, title: title(for: tool), status: status(for: tool))
        }
        steps.append(Chunk(id: 4, title: "Waiting for plan…", status: tools.contains { $0.state == .running } ? .pending : .inProgress))
        return steps
    }

    private func title(for tool: ActivityEntry) -> String {
        let file = tool.file.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard tool.state == .running else {
            return [tool.displayTitle, file].compactMap { $0 }.joined(separator: " · ")
        }
        switch tool.title {
        case "Read", "read_file": return "Reading \(file ?? "file")…"
        case "Glob", "Grep": return "Searching files…"
        case "Bash", "exec_command", "shell", "shell_command": return "Running command…"
        case "Edit", "Write", "apply_patch": return "Editing \(file ?? "files")…"
        case "exec": return "Running tool actions…"
        default: return "Running \(tool.displayTitle)…"
        }
    }

    private func status(for tool: ActivityEntry) -> ChunkStatus {
        switch tool.state {
        case .running: .inProgress
        case .failed: .blocked
        case .completed, .unknown: .done
        }
    }
}
