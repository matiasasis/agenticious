import Darwin
import Foundation

/// SwiftTerm 1.11 stops watching the shell once the terminal reads end-of-file, which an exit usually causes first,
/// so it rarely reports the exit. This watch reaps the process and reports what it exited with.
final class ProcessExitWatch {
    private let source: DispatchSourceProcess

    /// Fires once, on the main queue. A process that already exited still fires.
    init(pid: pid_t, onExit: @escaping @MainActor (Int32?) -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [source] in
            var status: Int32 = 0
            let reaped = waitpid(pid, &status, WNOHANG) == pid
            source.cancel()
            // Nothing to reap: SwiftTerm's own watch got there first, and it reports the exit itself.
            guard reaped else { return }
            MainActor.assumeIsolated { onExit(ProcessExitWatch.exitCode(fromWaitStatus: status)) }
        }
        source.activate()
    }

    deinit { source.cancel() }

    /// The exit code in a raw wait status, or nil when a signal ended the process.
    static func exitCode(fromWaitStatus status: Int32) -> Int32? {
        status & 0x7f == 0 ? (status >> 8) & 0xff : nil
    }
}
