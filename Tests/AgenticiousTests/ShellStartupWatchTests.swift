import XCTest
@testable import Agenticious

final class ShellStartupWatchTests: XCTestCase {
    private let question = "[oh-my-zsh] Would you like to update? [Y/n]"

    private func sample(cpu: UInt64? = 0, keys: Bool = false, hides: Bool = false, row: String? = nil, before: String? = nil,
                        foreground: String? = nil, screen: [String]? = nil, image: ShellSample.Image = .shell) -> ShellSample {
        ShellSample(image: image, cpuSincePrevious: cpu, readsSingleKeys: keys, hidesTyping: hides, cursorRow: row,
                    textBeforeCursor: before, foreground: foreground, screen: screen ?? [row ?? ""])
    }

    private func observe(_ samples: [ShellSample]) -> [ShellWait?] {
        var watch = ShellStartupWatch()
        return samples.map { watch.observe($0) }
    }

    func testAKeyWaitShowsOnTheSecondIdleSampleAfterThePrimingOne() {
        let key = sample(keys: true, row: question)
        let results = observe([sample(cpu: nil, keys: true, row: question), key, key])
        XCTAssertEqual(results.prefix(2), [nil, nil])
        XCTAssertEqual(results[2], ShellWait(kind: .key, text: question, program: nil))
    }

    func testAPasswordWaitNamesTheProgram() {
        let password = sample(hides: true, row: "Password:", foreground: "sudo")
        XCTAssertEqual(observe([sample(cpu: nil), password, password]).last, ShellWait(kind: .password, text: "Password:", program: "sudo"))
    }

    func testAFullScreenProgramIsAKeyWaitNotAPassword() {
        // tmux or fzf from a start-up file: raw mode with echo off.
        let tui = sample(keys: true, hides: true, row: "", foreground: "tmux")
        XCTAssertEqual(observe([sample(cpu: nil), tui, tui]).last, ShellWait(kind: .key, text: "", program: "tmux"))
    }

    func testAnAnsweredPasswordDoesNotComeBackAsALineQuestion() {
        let asked = sample(hides: true, row: "Password:", before: "Password:")
        // Answered: echo is back, the cursor still sits after the prompt, and start-up works on quietly.
        let answered = sample(row: "Password:", before: "Password:")
        let results = observe([sample(cpu: nil, hides: true, row: "Password:", before: "Password:"), asked, asked] + Array(repeating: answered, count: 8))
        XCTAssertEqual(results[2]?.kind, .password)
        XCTAssertEqual(results.suffix(8), Array(repeating: nil, count: 8))
        // New output on screen is a new question, and can show again.
        let next = sample(row: "Continue?", before: "Continue?")
        XCTAssertEqual(observe([sample(cpu: nil, hides: true, row: "Password:", before: "Password:"), asked, asked, answered]
                               + Array(repeating: next, count: 5)).last??.kind, .line)
    }

    func testBusyOrChangingSamplesStartTheCountAgain() {
        let key = sample(keys: true, row: question)
        XCTAssertEqual(observe([sample(cpu: nil), key, sample(cpu: 50_000_000, keys: true, row: question), key]).last, .some(nil))
        XCTAssertEqual(observe([sample(cpu: nil), key, sample(cpu: 50_000_000, keys: true, row: question), key, key]).last!?.kind, .key)
        let moved = sample(keys: true, row: question, screen: [question, "more"])
        XCTAssertEqual(observe([sample(cpu: nil), key, moved]).last, .some(nil))
        XCTAssertNotNil(observe([sample(cpu: nil), key, moved, moved]).last!)
    }

    func testALineQuestionNeedsFiveIdleSamples() {
        let line = sample(row: "Continue?", before: "Continue?")
        let results = observe([sample(cpu: nil)] + Array(repeating: line, count: 5))
        XCTAssertTrue(results.dropLast().allSatisfy { $0 == nil })
        XCTAssertEqual(results.last, ShellWait(kind: .line, text: "Continue?", program: nil))
    }

    func testSlowStartUpsNeverShow() {
        for quiet in [sample(row: "Loading plugins...", before: "Loading plugins..."), sample(), sample(foreground: "sleep")] {
            XCTAssertTrue(observe([sample(cpu: nil)] + Array(repeating: quiet, count: 20)).allSatisfy { $0 == nil })
        }
    }

    func testAShownWaitStaysThroughCPUAndClearsWhenTheTerminalChanges() {
        let key = sample(keys: true, row: question)
        let shown = [sample(cpu: nil), key, key, sample(cpu: 90_000_000, keys: true, row: question)]
        XCTAssertNotNil(observe(shown).last!)
        XCTAssertEqual(observe(shown + [sample(row: question)]).last, .some(nil))
        XCTAssertEqual(observe(shown + [sample(keys: true, row: question, screen: [question, "y"])]).last, .some(nil))
    }

    func testAReplacedOrEndedShellFinishesTheWatch() {
        for image in [ShellSample.Image.replaced, .gone] {
            var watch = ShellStartupWatch()
            let key = sample(keys: true, row: question)
            _ = [sample(cpu: nil), key, key].map { watch.observe($0) }
            XCTAssertNotNil(watch.shown)
            XCTAssertNil(watch.observe(sample(image: image)))
            XCTAssertTrue(watch.isFinished)
            XCTAssertNil(watch.shown)
            XCTAssertNil(watch.observe(key))
        }
    }

    /// The CLI's own raw-mode screen comes after exec, so it never reads as the shell waiting.
    func testTheAgentsOwnScreenIsNeverAShellWait() {
        let claude = sample(keys: true, row: ">", before: ">", screen: ["⏺ Read(file)", "", ">"], image: .replaced)
        XCTAssertTrue(observe([sample(cpu: nil), claude, claude, claude]).allSatisfy { $0 == nil })
    }

    func testWhatReadsLikeAQuestion() {
        for line in ["Continue?", "[Y/n]", "Password:", ">", "(y)"] { XCTAssertTrue(ShellStartupWatch.readsLikeQuestion(line), line) }
        for line in ["Loading plugins...", "Done", ""] { XCTAssertFalse(ShellStartupWatch.readsLikeQuestion(line), line) }
    }

    func testReasonsQuoteTheShellAndHintOnlyForOhMyZsh() {
        let update = ShellWait(kind: .key, text: question, program: nil).reason(before: "Claude Code")
        XCTAssertEqual(update, "Your shell start-up is waiting for an answer before Claude Code starts: “\(question)”. Answer it in the terminal."
                       + " To stop Oh My Zsh asking here, set zstyle ':omz:update' mode to reminder in ~/.zshrc.")
        XCTAssertFalse(ShellWait(kind: .line, text: "Continue?", program: nil).reason(before: "Codex").contains("zstyle"))
        XCTAssertEqual(ShellWait(kind: .password, text: "Enter passphrase for key:", program: "ssh-add").reason(before: "Codex"),
                       "Your shell start-up is asking for a password (ssh-add) before Codex starts: “Enter passphrase for key:”. Type it in the terminal.")
        XCTAssertEqual(ShellWait(kind: .key, text: "", program: nil).reason(before: "Codex"),
                       "Your shell start-up is waiting for an answer before Codex starts. Answer it in the terminal.")
    }
}
