import AppKit
import XCTest
@testable import Agenticious

final class SummonPanelTests: XCTestCase {
    func testPanelRunsEditingKeysItselfAndKeepsOtherCommandKeysFromTheMenus() {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> SummonKey { SummonKey(characters: characters, flags: flags) }
        XCTAssertEqual(key("v", .command), .edit(.paste))
        XCTAssertEqual(key("c", .command), .edit(.copy))
        XCTAssertEqual(key("x", .command), .edit(.cut))
        XCTAssertEqual(key("a", .command), .edit(.selectAll))
        XCTAssertEqual(key("z", .command), .edit(.undo))
        XCTAssertEqual(key("z", [.command, .shift]), .edit(.redo))
        XCTAssertEqual(key("V", [.command, .capsLock]), .edit(.paste))
        XCTAssertEqual(key("w", .command), .cancel)
        for menuKey in ["q", "n", ",", "h", "m"] { XCTAssertEqual(key(menuKey, .command), .swallow, menuKey) }
        XCTAssertEqual(key("v", [.command, .option]), .swallow)
        // Text editing, not menu commands: the text view must still get them.
        XCTAssertEqual(key("\u{F702}", [.command, .function, .numericPad]), .pass)
        XCTAssertEqual(key("\u{7F}", .command), .pass)
        XCTAssertEqual(key("\r", .command), .pass)
        XCTAssertEqual(key("v", []), .pass)
        XCTAssertEqual(key("a", .control), .pass)
        XCTAssertEqual(key("\u{1B}", []), .pass)
        // Emoji & Symbols is answered by a hidden Edit-menu item.
        XCTAssertEqual(key(" ", [.command, .control]), .pass)
    }

    @MainActor
    func testEditCommandsReachTheTextViewWithoutAMenu() {
        let panel = SummonPanel()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        text.allowsUndo = true
        panel.contentView = text
        panel.makeFirstResponder(text)
        text.insertText("hello", replacementRange: NSRange(location: 0, length: 0))
        SummonEditCommand.selectAll.perform(on: panel.firstResponder, sender: panel)
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 5))
        SummonEditCommand.undo.perform(on: panel.firstResponder, sender: panel)
        XCTAssertEqual(text.string, "")
        SummonEditCommand.redo.perform(on: panel.firstResponder, sender: panel)
        XCTAssertEqual(text.string, "hello")
        // Nothing left to redo: a no-op, not an exception.
        SummonEditCommand.redo.perform(on: panel.firstResponder, sender: panel)
        XCTAssertEqual(text.string, "hello")
    }

    @MainActor
    func testPanelTakesTheKeyboardWithoutActivatingAndStaysWhileAnotherAppIsInFront() {
        let panel = SummonPanel()
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertTrue(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.canHide)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .fullScreenAuxiliary]))
        var cancelled = 0
        panel.onCancel = { cancelled += 1 }
        panel.cancelOperation(nil)
        XCTAssertEqual(cancelled, 1)
    }

    func testPanelOpensInTheMiddleOfTheMainDisplayAndStaysOnIt() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 960, height: 775), in: visible), CGRect(x: 240, y: 75, width: 960, height: 775))
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 401, height: 301), in: visible), CGRect(x: 520, y: 312, width: 401, height: 301))
        // Larger than the display: it fills it rather than running past an edge.
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 2000, height: 2000), in: visible), visible)
        // A main display that isn't at the origin of the desktop.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let frame = SummonPlacement.frame(size: CGSize(width: 960, height: 775), in: left)
        XCTAssertEqual(frame.midX, left.midX)
        XCTAssertTrue(left.contains(frame))
    }
}
