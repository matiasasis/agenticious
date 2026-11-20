import Darwin
import Foundation
import SwiftTerm

/// What an agent's login shell waits for before it runs the CLI.
struct ShellWait: Equatable {
    enum Kind: Equatable {
        /// The terminal reads single keys: `read -k`, `read -q`, Oh My Zsh's update question, compinit.
        case key
        /// The terminal hides typing: ssh-add, sudo, `read -s`.
        case password
        /// A plain line read, recognised only by the question the cursor sits after.
        case line
    }

    let kind: Kind
    /// The cursor's row as the terminal shows it, cleaned. Empty when the shell printed nothing there.
    let text: String
    /// The program in the terminal's foreground when it isn't the shell, like `ssh-add` or `sudo`.
    let program: String?

    var isOhMyZshUpdate: Bool {
        text.range(of: #"^\[(oh-my-zsh|Oh My Zsh)\] Would you like to update\?"#, options: .regularExpression) != nil
    }

    func reason(before agent: String) -> String {
        let quoted = text.isEmpty ? "" : ": “\(TerminalScreen.oneLine(text))”"
        let by = program.map { " (\($0))" } ?? ""
        switch kind {
        case .password:
            return "Your shell start-up is asking for a password\(by) before \(agent) starts\(quoted). Type it in the terminal."
        case .key, .line:
            let reason = "Your shell start-up is waiting for an answer\(by) before \(agent) starts\(quoted). Answer it in the terminal."
            guard isOhMyZshUpdate else { return reason }
            return reason + " To stop Oh My Zsh asking here, set zstyle ':omz:update' mode to reminder in ~/.zshrc."
        }
    }
}

/// One reading of the login shell, taken from outside it.
struct ShellSample: Equatable {
    enum Image: Equatable {
        /// Still the shell (or the app's own fork, before the shell's exec): start-up files are running.
        case shell
        /// The shell exec'd the command. A shim or the CLI runs now; a failure from here on is an exit.
        case replaced
        /// Exited, or a zombie nobody reaped yet.
        case gone
    }

    var image: Image
    /// CPU the shell and the terminal's foreground job used since the previous sample. Nil on the first.
    var cpuSincePrevious: UInt64?
    var readsSingleKeys = false
    var hidesTyping = false
    var cursorRow: String?
    var textBeforeCursor: String?
    var foreground: String?
    var screen: [String] = []
}

/// Decides from successive samples whether the shell waits for the human. A slow start-up never counts as waiting:
/// a wait needs an idle shell, a terminal set to read keys or hide typing (or a question the cursor sits after),
/// and an unchanged screen over several samples.
struct ShellStartupWatch {
    /// CPU the shell and its foreground job may use between two samples and still count as idle.
    static let idleBudget: UInt64 = 20_000_000

    /// Matching samples in a row, about 2 s apart, before a wait shows. A question alone is a weaker sign.
    static func samplesNeeded(for kind: ShellWait.Kind) -> Int { kind == .line ? 5 : 2 }

    private(set) var shown: ShellWait?
    /// The shell exec'd or ended. Nothing more to watch.
    private(set) var isFinished = false
    private var candidate: ShellWait?
    private var streak = 0
    private var screen: [String]?
    /// The screen a key or password wait was answered on. Its question stays in view, but it was answered.
    private var answeredScreen: [String]?

    mutating func observe(_ sample: ShellSample) -> ShellWait? {
        guard !isFinished else { return nil }
        guard sample.image == .shell else {
            isFinished = true
            shown = nil
            return nil
        }
        defer { screen = sample.screen }
        let wait = Self.wait(in: sample)
        // A wait that shows stays while the terminal still reads like it. CPU alone doesn't clear it: typing does.
        if let shown, wait == shown, sample.screen == screen { return shown }
        if let shown, shown.kind != .line { answeredScreen = screen }
        shown = nil
        let isIdle = sample.cpuSincePrevious.map { $0 <= Self.idleBudget } ?? false
        guard isIdle, let wait, wait.kind != .line || sample.screen != answeredScreen else {
            candidate = nil
            streak = 0
            return nil
        }
        if wait == candidate, sample.screen == screen { streak += 1 } else { (candidate, streak) = (wait, 1) }
        if streak >= Self.samplesNeeded(for: wait.kind) { shown = wait }
        return shown
    }

    static func wait(in sample: ShellSample) -> ShellWait? {
        // Password readers keep line mode; raw mode with echo off is a full-screen program (tmux, fzf), not a password.
        if sample.readsSingleKeys { return ShellWait(kind: .key, text: sample.cursorRow ?? "", program: sample.foreground) }
        if sample.hidesTyping { return ShellWait(kind: .password, text: sample.cursorRow ?? "", program: sample.foreground) }
        guard let text = sample.textBeforeCursor, readsLikeQuestion(text) else { return nil }
        return ShellWait(kind: .line, text: text, program: sample.foreground)
    }

    /// "Continue? ", "[Y/n] ", "Password: ", "> ". Not "Loading plugins...".
    static func readsLikeQuestion(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return "?:]>)".contains(last)
    }
}

/// Reads the login shell from outside: `zsh -lic "exec cli"` keeps one pid, which runs the start-up files and is
/// then replaced by the CLI (or a shim that execs it). So while the pid still runs the shell, start-up isn't done.
struct ShellStartupProbe {
    let shellPath: String
    private var lastCPU: UInt64?
    /// Between fork and exec the child still runs this app's own executable.
    private static let ownPath = executablePath(of: getpid())

    init(shellPath: String) {
        // The path the kernel reports, should the launcher ever name a symlink.
        self.shellPath = URL(fileURLWithPath: shellPath).resolvingSymlinksInPath().path
    }

    /// Main thread only, like the terminal. Reads `process` live: SwiftTerm sets childfd to -1 at end-of-file, and a
    /// closed descriptor's number may already belong to something else.
    mutating func sample(_ process: LocalProcess, _ terminal: Terminal) -> ShellSample {
        let pid = process.shellPid
        let fd = process.childfd
        guard pid > 0, fd >= 0, process.running, let image = Self.executablePath(of: pid) else { return ShellSample(image: .gone) }
        guard image == shellPath || image == Self.ownPath else { return ShellSample(image: .replaced) }

        let foreground = tcgetpgrp(fd)
        var cpu = Self.cpuNanoseconds(of: pid)
        if foreground > 0, foreground != pid { cpu += Self.cpuNanoseconds(of: foreground) }
        // A foreground job that changed between samples can make the sum drop; that reads as busy.
        let used = lastCPU.map { cpu >= $0 ? cpu - $0 : .max }
        lastCPU = cpu

        var mode = termios()
        let hasMode = tcgetattr(fd, &mode) == 0
        let rows = TerminalScreen.rows(of: terminal)
        return ShellSample(
            image: .shell,
            cpuSincePrevious: used,
            readsSingleKeys: hasMode && mode.c_lflag & tcflag_t(ICANON) == 0,
            hidesTyping: hasMode && mode.c_lflag & tcflag_t(ECHO) == 0,
            cursorRow: TerminalScreen.cursorRow(of: terminal, rows: rows),
            textBeforeCursor: TerminalScreen.textBeforeCursor(of: terminal, rows: rows),
            foreground: foreground > 0 && foreground != pid ? Self.name(of: foreground) : nil,
            screen: rows
        )
    }

    /// Nil for a pid that is gone, and for a zombie, though kill(pid, 0) still succeeds on one.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func cpuNanoseconds(of pid: pid_t) -> UInt64 {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return 0 }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return (info.ri_user_time + info.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
