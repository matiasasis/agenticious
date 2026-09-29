import Foundation
import Darwin

struct CleanupResult {
    var processesStopped = false
    var worktreeRemoved = false
    var warnings: [String] = []
}

enum SessionCleanup {
    static func run(id: UUID, processID: Int32?, worktree: Worktree?, sharedWorktree: Bool,
                    supportDirectory: URL? = nil) -> CleanupResult {
        var result = CleanupResult()
        do {
            try stopProcesses(id: id, processID: processID)
            result.processesStopped = true
        } catch {
            result.warnings.append("Couldn't stop all agent processes. Cleanup was halted; retry archive: \(error.localizedDescription)")
            return result
        }
        if let worktree {
            if sharedWorktree {
                result.warnings.append("Archived the agent, but kept its worktree because another queued agent uses it.")
            } else {
                do {
                    try Worktrees.remove(worktree)
                    result.worktreeRemoved = true
                } catch {
                    result.warnings.append("Archived the agent, but kept its worktree: \(error.localizedDescription)")
                }
            }
        }
        let support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configuration = support.appendingPathComponent("Agenticious/sessions/\(id.uuidString)")
        do {
            if FileManager.default.fileExists(atPath: configuration.path) {
                try FileManager.default.removeItem(at: configuration)
            }
        } catch {
            result.warnings.append("Couldn't remove the agent's temporary configuration: \(error.localizedDescription)")
        }
        return result
    }

    private static func stopProcesses(id: UUID, processID: Int32?) throws {
        let initial = try processes()
        let roots = initial.filter { $0.pid == processID || $0.belongs(to: id) }
        let groups = roots.map(\.pid).filter { $0 > 1 && $0 != getpgrp() && getpgid($0) == $0 }
        var targets = descendants(of: roots, in: initial)
        for group in groups { kill(-group, SIGTERM) }
        try signal(targets, SIGTERM)
        Thread.sleep(forTimeInterval: 0.2)
        let current = try processes()
        targets = descendants(of: current.filter { candidate in
            targets.contains { $0.sameProcess(as: candidate) } || candidate.belongs(to: id)
        }, in: current)
        for group in groups { kill(-group, SIGKILL) }
        try signal(targets, SIGKILL)
        for _ in 0..<20 {
            let remaining = try processes().filter { candidate in targets.contains { $0.sameProcess(as: candidate) } }
            if remaining.isEmpty { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw WorktreeError.git("Some agent processes are still running; retry archive cleanup.")
    }

    static func descendants(of roots: [CleanupProcess], in processes: [CleanupProcess]) -> [CleanupProcess] {
        var ids = Set(roots.map(\.pid))
        while true {
            let children = Set(processes.filter { ids.contains($0.parent) }.map(\.pid))
            let expanded = ids.union(children)
            if expanded == ids { return processes.filter { ids.contains($0.pid) && $0.pid != getpid() && $0.pid > 1 } }
            ids = expanded
        }
    }

    private static func signal(_ processes: [CleanupProcess], _ signal: Int32) throws {
        for process in processes.reversed() {
            if kill(process.pid, signal) != 0 && errno != ESRCH { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
        }
    }

    private static func processes() throws -> [CleanupProcess] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-U", String(getuid()), "-ww", "-o", "pid=,ppid=,stat=,lstart=,command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw WorktreeError.git("Couldn't inspect agent processes.") }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { CleanupProcess(line: String($0)) }
    }
}

struct CleanupProcess {
    let pid: Int32
    let parent: Int32
    let started: String
    let command: String

    init?(line: String) {
        let fields = line.split(maxSplits: 8, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
        guard fields.count == 9, let pid = Int32(fields[0]), let parent = Int32(fields[1]), !fields[2].contains("Z") else { return nil }
        self.pid = pid
        self.parent = parent
        started = fields[3...7].joined(separator: " ")
        command = String(fields[8])
    }

    func sameProcess(as other: CleanupProcess) -> Bool { pid == other.pid && started == other.started }

    func belongs(to id: UUID) -> Bool {
        let command = command.lowercased()
        let executable = URL(fileURLWithPath: command.components(separatedBy: " ")[0]).lastPathComponent
        guard ["codex", "claude", "node"].contains(executable) else { return false }
        let id = id.uuidString.lowercased()
        return command.contains("agenticious_session=\"\(id)\"")
            || command.contains("/agenticious/sessions/\(id)/settings.json")
    }
}
