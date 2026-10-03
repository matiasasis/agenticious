import Foundation

/// A shell command that undoes something an agent made outside its worktree's files, like a test database,
/// another worktree, or a background server. It runs when the agent is ended or archived, before its worktree goes.
struct CleanupTask: Codable, Equatable, Identifiable {
    let command: String
    let title: String

    var id: String { command }

    init(command: String, title: String? = nil) {
        self.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.title = title.isEmpty ? self.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? "" : title
    }

    /// A workspace's commands, one per line. Blank lines and `#` comments are skipped.
    static func parse(_ text: String) -> [CleanupTask] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { CleanupTask(command: $0) }
    }
}

extension AgentSession {
    /// Registering the same command twice keeps one, with the newer title.
    func addCleanup(_ task: CleanupTask) {
        guard !task.command.isEmpty else { return }
        cleanupTasks.removeAll { $0.command == task.command }
        cleanupTasks.append(task)
    }
}

/// Cleanup commands set for a whole workspace, run for every agent in it. Kept per project folder in user defaults.
enum WorkspaceCleanup {
    private static let key = "workspaceCleanup"

    static func text(for project: Project, defaults: UserDefaults = .standard) -> String {
        guard let path = project.path else { return "" }
        return (defaults.dictionary(forKey: key) as? [String: String])?[path] ?? ""
    }

    static func setText(_ text: String, for project: Project, defaults: UserDefaults = .standard) {
        guard let path = project.path else { return }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        all[path] = trimmed.isEmpty ? nil : trimmed
        defaults.set(all, forKey: key)
    }

    static func tasks(for project: Project, defaults: UserDefaults = .standard) -> [CleanupTask] {
        CleanupTask.parse(text(for: project, defaults: defaults))
    }
}

enum CleanupRunner {
    enum Outcome: Equatable {
        case succeeded
        case failed(String)
    }

    /// Runs one command in a login shell, so it sees the user's PATH like the agent did. Gives up after `timeout`.
    static func run(_ task: CleanupTask, in directory: URL, environment: [String: String], timeout: TimeInterval = 120) -> Outcome {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("agenticious-cleanup-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: output) }
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let log = try? FileHandle(forWritingTo: output) else { return .failed("couldn't capture its output") }
        defer { try? log.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", task.command]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .failed(error.localizedDescription) }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failed("still running after \(Int(timeout)) seconds, so it was stopped")
        }
        guard process.terminationStatus != 0 else { return .succeeded }
        let lastLine = (try? String(contentsOf: output, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        return .failed("exit \(process.terminationStatus)" + (lastLine.map { ": \($0)" } ?? ""))
    }
}
