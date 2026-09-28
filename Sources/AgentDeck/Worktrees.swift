import Foundation

struct Worktree: Equatable {
    let repositoryRoot: String
    let path: String
    let branch: String
}

enum WorktreeError: LocalizedError {
    case git(String)

    var errorDescription: String? {
        switch self {
        case let .git(message): message
        }
    }
}

/// Git worktrees so parallel agents in one repo don't edit the same checkout.
/// They live in `<repo>/.claude/worktrees/<slug>`, Claude Code's own convention: inside the repo,
/// so Claude trusts them without asking, and excluded locally through `.git/info/exclude`.
enum Worktrees {
    static let folder = ".claude/worktrees"

    static func repositoryRoot(of path: String) -> String? {
        try? git(["rev-parse", "--show-toplevel"], in: path)
    }

    static func create(in projectPath: String, for task: String) throws -> Worktree {
        guard let root = repositoryRoot(of: projectPath) else { throw WorktreeError.git("\(projectPath) isn't a git repository.") }

        let slug = slug(for: task)
        let worktree = Worktree(repositoryRoot: root, path: "\(root)/\(folder)/\(slug)", branch: "agentdeck/\(slug)")

        try excludeLocally(in: root)
        try git(["worktree", "add", "-b", worktree.branch, worktree.path, "HEAD"], in: root)

        return worktree
    }

    /// Refuses when the worktree has uncommitted changes; the branch is kept either way.
    static func remove(_ worktree: Worktree) throws {
        try git(["worktree", "remove", worktree.path], in: worktree.repositoryRoot)
    }

    /// Keeps the worktrees folder out of `git status` without touching the repo's committed .gitignore.
    private static func excludeLocally(in root: String) throws {
        let exclude = URL(fileURLWithPath: try git(["rev-parse", "--git-path", "info/exclude"], in: root), relativeTo: URL(fileURLWithPath: root + "/"))
        let pattern = "/\(folder)/"
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(pattern)) else { return }

        try FileManager.default.createDirectory(at: exclude.deletingLastPathComponent(), withIntermediateDirectories: true)
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + separator + pattern + "\n").write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// "Fix the flaky onboarding spec!" → "fix-the-flaky-onboarding-3f2a"
    private static func slug(for task: String) -> String {
        let words = task.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(4)
        let suffix = UUID().uuidString.prefix(4).lowercased()
        return (words + [suffix]).joined(separator: "-")
    }

    /// Prefer a real git from PATH or Homebrew: `/usr/bin/git` is Apple's shim, which breaks whenever the Xcode or
    /// Command Line Tools install is broken. A GUI app's PATH is minimal, hence the explicit Homebrew locations.
    private static let gitBinary: String = {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let candidates = path + ["/opt/homebrew/bin", "/usr/local/bin"]
        return candidates.map { "\($0)/git" }.first { $0 != "/usr/bin/git" && FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/git"
    }()

    @discardableResult
    private static func git(_ arguments: [String], in directory: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: gitBinary)
        process.arguments = ["-C", directory] + arguments
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw WorktreeError.git(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
