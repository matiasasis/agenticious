import Darwin
import SwiftTerm
import XCTest
@testable import Agenticious

/// Real login shells in a pty, with their own HOME and ZDOTDIR, read the way the app reads an agent's start-up.
/// Samples every 0.5 s, since the watch counts samples rather than seconds.
final class ShellStartupIntegrationTests: XCTestCase {
    private var home: URL!
    private var hosts: [HeadlessTerminal] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("shell-startup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for pid in hosts.map(\.process.shellPid) where pid > 0 {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        hosts = []
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private func start(zshrc: String, command: String, environment: [String] = []) throws -> HeadlessTerminal {
        try zshrc.write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let host = HeadlessTerminal(options: TerminalOptions(cols: 120, rows: 30), onEnd: { _ in })
        host.process.startProcess(executable: "/bin/zsh", args: ["-lic", command],
                                  environment: ["HOME=\(home.path)", "ZDOTDIR=\(home.path)", "PATH=/usr/bin:/bin", "TERM=xterm-256color"] + environment,
                                  currentDirectory: home.path)
        hosts.append(host)
        XCTAssertGreaterThan(host.process.shellPid, 0)
        return host
    }

    /// Samples until the watch shows a wait or finishes, or the time is up. Returns every result.
    @MainActor
    private func watch(_ host: HeadlessTerminal, until deadline: TimeInterval = 4.5, stopAtWait: Bool = true) -> (results: [ShellWait?], finished: Bool) {
        var probe = ShellStartupProbe(shellPath: "/bin/zsh")
        var watch = ShellStartupWatch()
        var results: [ShellWait?] = []
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            results.append(watch.observe(probe.sample(host.process, host.terminal)))
            if watch.isFinished || (stopAtWait && results.last! != nil) { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
        return (results, watch.isFinished)
    }

    @MainActor
    func testOhMyZshUpdateQuestionShowsAsAKeyWait() throws {
        let question = "[oh-my-zsh] Would you like to update? [Y/n]"
        let host = try start(zshrc: "read -k 1 '?\(question) '\n", command: "exec /bin/sleep 30")
        let wait = try XCTUnwrap(watch(host).results.last ?? nil)
        XCTAssertEqual(wait.kind, .key)
        XCTAssertEqual(wait.text, question)
        XCTAssertTrue(wait.isOhMyZshUpdate)
    }

    @MainActor
    func testASlowStartUpStaysQuietAndFinishes() throws {
        let host = try start(zshrc: "sleep 3\n", command: "exec /bin/sleep 30")
        let (results, finished) = watch(host, stopAtWait: false)
        XCTAssertTrue(results.allSatisfy { $0 == nil })
        XCTAssertTrue(finished)
    }

    @MainActor
    func testACLIThatCannotStartIsReportedWithItsLinesAndCode() throws {
        let stub = home.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf 'nodenv: claude: command not found\\n\\nThe `claude'"'"' command exists in these Node versions:\\n  20.18.0\\n\\n' >&2
        exit 127
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let host = try start(zshrc: "", command: "exec \(stub.path)")
        var codes: [Int32?] = []
        let exited = expectation(description: "exit")
        let exitWatch = ProcessExitWatch(pid: host.process.shellPid) { codes.append($0); exited.fulfill() }
        wait(for: [exited], timeout: 4.5)
        // As the app does: lines drawn after the exit arrive on the next turns of the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(codes, [127])
        let output = TerminalScreen.lastLines(of: host.terminal)
        XCTAssertEqual(output.suffix(4), ["nodenv: claude: command not found", "", "The `claude' command exists in these Node versions:", "  20.18.0"])
        let diagnosis = try XCTUnwrap(LaunchFailure(code: codes[0], output: output, resuming: false).diagnosis(for: .claude))
        XCTAssertEqual(diagnosis.fix, "npm install -g @anthropic-ai/claude-code")
        XCTAssertTrue(diagnosis.cause.contains("installed for 20.18.0"))
        withExtendedLifetime(exitWatch) {}
    }

    /// The launcher's own prefix: start-up files see the switches, the CLI doesn't.
    @MainActor
    func testTheCLIDoesNotInheritTheStartupSwitches() throws {
        let session = AgentSession(task: "Check", agent: .claude, project: .none, directory: home)
        let spec = try AgentLauncher(port: 1, supportDirectory: home, inherited: [:]).spec(for: session)
        let command = spec.arguments[1]
        let exec = try XCTUnwrap(command.range(of: "exec claude"))
        let prefix = String(command[..<exec.lowerBound])
        let switches = spec.environment.filter { AgentLauncher.startupSwitches.keys.contains(String($0.prefix { $0 != "=" })) }
        XCTAssertEqual(switches.count, 2)
        let host = try start(zshrc: "echo \"rc saw $DISABLE_AUTO_UPDATE $ZSH_TMUX_AUTOSTARTED\"\n", command: prefix + "exec /usr/bin/env",
                             environment: switches)
        let exited = expectation(description: "exit")
        let exitWatch = ProcessExitWatch(pid: host.process.shellPid) { _ in exited.fulfill() }
        wait(for: [exited], timeout: 4.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let screen = TerminalScreen.rows(of: host.terminal).joined(separator: "\n")
        XCTAssertTrue(screen.contains("rc saw true true"), screen)
        XCTAssertTrue(screen.contains("ZDOTDIR="), screen)
        XCTAssertFalse(screen.contains("DISABLE_AUTO_UPDATE="), screen)
        XCTAssertFalse(screen.contains("ZSH_TMUX_AUTOSTARTED="), screen)
        withExtendedLifetime(exitWatch) {}
    }
}
