import SwiftTerm
import XCTest
@testable import Agenticious

final class TerminalScreenTests: XCTestCase {
    private func terminal(rows: Int = 10) -> HeadlessTerminal {
        HeadlessTerminal(options: TerminalOptions(cols: 80, rows: rows), onEnd: { _ in })
    }

    private func feed(_ text: String, to host: HeadlessTerminal) {
        host.terminal.feed(buffer: Array(text.utf8)[...])
    }

    func testRowsAreTheVisibleScreenWhateverTheScrollPosition() {
        let host = terminal()
        feed((1...30).map { "line \($0)" }.joined(separator: "\r\n"), to: host)
        host.terminal.buffer.yDisp = 0
        XCTAssertEqual(TerminalScreen.rows(of: host.terminal), (21...30).map { "line \($0)" })
    }

    func testTextBeforeCursorOnlyWhenTheCursorSitsAfterIt() {
        let host = terminal()
        feed("Loading\r\nContinue? ", to: host)
        XCTAssertEqual(TerminalScreen.textBeforeCursor(of: host.terminal, rows: TerminalScreen.rows(of: host.terminal)), "Continue?")
        XCTAssertEqual(TerminalScreen.cursorRow(of: host.terminal, rows: TerminalScreen.rows(of: host.terminal)), "Continue?")
        feed("\u{1b}[5D", to: host)
        XCTAssertNil(TerminalScreen.textBeforeCursor(of: host.terminal, rows: TerminalScreen.rows(of: host.terminal)))
        feed("\r\n", to: host)
        XCTAssertNil(TerminalScreen.textBeforeCursor(of: host.terminal, rows: TerminalScreen.rows(of: host.terminal)))
        XCTAssertNil(TerminalScreen.cursorRow(of: host.terminal, rows: TerminalScreen.rows(of: host.terminal)))
    }

    func testLastLinesKeepWhatAFailedStartPrinted() {
        let host = terminal()
        feed("nodenv: claude: command not found\r\n\r\nThe `claude' command exists in these Node versions:\r\n  20.18.0\r\n\r\n", to: host)
        XCTAssertEqual(TerminalScreen.lastLines(of: host.terminal), [
            "nodenv: claude: command not found", "", "The `claude' command exists in these Node versions:", "  20.18.0",
        ])
        XCTAssertEqual(TerminalScreen.lastLines(of: terminal().terminal), [])
    }

    func testCleanDropsHiddenMarksAndBoundsLength() {
        XCTAssertEqual(TerminalScreen.clean("a\u{202E}b\u{200B}c\u{FEFF}d"), "abcd")
        XCTAssertEqual(TerminalScreen.clean("x\u{1b}y\u{07}z"), "x y z")
        let long = TerminalScreen.clean(String(repeating: "a", count: 400))
        XCTAssertEqual(long.count, 300)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(TerminalScreen.oneLine("a   b\t c  "), "a b c")
    }
}
