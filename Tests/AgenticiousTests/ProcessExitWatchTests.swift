import Darwin
import SwiftTerm
import XCTest
@testable import Agenticious

final class ProcessExitWatchTests: XCTestCase {
    private var pids: [pid_t] = []

    override func tearDown() {
        for pid in pids {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
        }
        pids = []
        super.tearDown()
    }

    func testDecodesRawWaitStatus() {
        XCTAssertEqual(ProcessExitWatch.exitCode(fromWaitStatus: 32512), 127)
        XCTAssertEqual(ProcessExitWatch.exitCode(fromWaitStatus: 768), 3)
        XCTAssertEqual(ProcessExitWatch.exitCode(fromWaitStatus: 0), 0)
        XCTAssertNil(ProcessExitWatch.exitCode(fromWaitStatus: 9))
        XCTAssertNil(ProcessExitWatch.exitCode(fromWaitStatus: 0x7f))
    }

    @MainActor
    func testReportsTheExitCodeOnceAndReapsTheProcess() throws {
        let pid = try spawn("exit 3")
        var codes: [Int32?] = []
        let exited = expectation(description: "exit")
        let watch = ProcessExitWatch(pid: pid) { codes.append($0); exited.fulfill() }
        wait(for: [exited], timeout: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(codes, [3])
        XCTAssertNotReapable(pid)
        withExtendedLifetime(watch) {}
    }

    @MainActor
    func testReportsAProcessThatWasAlreadyAZombie() throws {
        let pid = try spawn("exit 5")
        // Nobody reaps it meanwhile, so the watch starts on a zombie.
        Thread.sleep(forTimeInterval: 0.3)
        var codes: [Int32?] = []
        let exited = expectation(description: "exit")
        let watch = ProcessExitWatch(pid: pid) { codes.append($0); exited.fulfill() }
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(codes, [5])
        XCTAssertNotReapable(pid)
        withExtendedLifetime(watch) {}
    }

    /// SwiftTerm's own report and the watch race; the session keeps the first, as attachTerminal's guard does.
    @MainActor
    func testEveryShellExitReachesTheSessionExactlyOnce() {
        for _ in 0..<20 {
            let exited = expectation(description: "exit")
            let host = ExitRecorder { exited.fulfill() }
            let process = LocalProcess(delegate: host)
            host.process = process
            process.startProcess(executable: "/bin/zsh", args: ["-f", "-c", "exit 127"], environment: ["PATH=/usr/bin:/bin"])
            let pid = process.shellPid
            XCTAssertGreaterThan(pid, 0)
            pids.append(pid)
            let watch = ProcessExitWatch(pid: pid) { host.deliver($0) }
            wait(for: [exited], timeout: 5)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(host.accepted, [127])
            XCTAssertNotReapable(pid)
            withExtendedLifetime(watch) {}
        }
    }

    private func spawn(_ script: String) throws -> pid_t {
        var pid: pid_t = 0
        let argv = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let result = posix_spawn(&pid, "/bin/sh", nil, nil, argv, nil)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        pids.append(pid)
        return pid
    }

    private func XCTAssertNotReapable(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "left a zombie", file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }
}

/// Stands in for TerminalBridge plus the session: decodes SwiftTerm's raw status and keeps only the first delivery.
private final class ExitRecorder: LocalProcessDelegate {
    weak var process: LocalProcess?
    private(set) var accepted: [Int32?] = []
    private let onFirst: () -> Void

    init(onFirst: @escaping () -> Void) { self.onFirst = onFirst }

    func deliver(_ code: Int32?) {
        guard accepted.isEmpty else { return }
        accepted.append(code)
        onFirst()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        let code = exitCode.flatMap(ProcessExitWatch.exitCode(fromWaitStatus:))
        DispatchQueue.main.async { self.deliver(code) }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {}

    func getWindowSize() -> winsize { winsize(ws_row: 24, ws_col: 80, ws_xpixel: 16, ws_ypixel: 16) }
}
