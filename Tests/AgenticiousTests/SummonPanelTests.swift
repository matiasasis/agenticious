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

    func testPanelIsCentredAndNeverRunsPastTheDisplay() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 960, height: 775), in: visible), CGRect(x: 240, y: 75, width: 960, height: 775))
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 400, height: 300), over: CGRect(x: 100, y: 100, width: 600, height: 500), in: visible),
                       CGRect(x: 200, y: 200, width: 400, height: 300))
        // A narrow window at the display's edge: the panel stays fully on it.
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 960, height: 775), over: CGRect(x: 1200, y: 600, width: 240, height: 275), in: visible),
                       CGRect(x: 480, y: 125, width: 960, height: 775))
        XCTAssertEqual(SummonPlacement.frame(size: CGSize(width: 2000, height: 2000), in: visible), visible)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1055)
        let frame = SummonPlacement.frame(size: CGSize(width: 960, height: 775), in: left)
        XCTAssertEqual(frame.midX, left.midX)
        XCTAssertTrue(left.contains(frame))
    }

    func testEachPositionPicksItsDisplayAndWindow() {
        let main = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let side = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let window = CGRect(x: 1600, y: 100, width: 800, height: 600)
        func target(_ position: SummonPosition, window: CGRect? = window, pointer: CGPoint = .zero) -> (visible: CGRect, window: CGRect?) {
            SummonPlacement.target(position, screens: [main, side], focusedWindow: window, pointer: pointer)
        }
        XCTAssertEqual(target(.mainDisplay).visible, main.visible)
        XCTAssertNil(target(.mainDisplay).window)
        XCTAssertEqual(target(.currentDisplay).visible, side.visible)
        XCTAssertNil(target(.currentDisplay).window, "the middle of the display, not over the window")
        XCTAssertEqual(target(.currentWindow).visible, side.visible)
        XCTAssertEqual(target(.currentWindow).window, window)
        // No front window known: the display under the pointer, and its middle.
        XCTAssertEqual(target(.currentWindow, window: nil, pointer: CGPoint(x: 2000, y: 500)).visible, side.visible)
        XCTAssertNil(target(.currentWindow, window: nil).window)
        XCTAssertEqual(SummonPlacement.target(.currentDisplay, screens: [], focusedWindow: nil, pointer: .zero).visible.width, 1040)
    }

    func testTheDisplayInUseIsTheFrontWindowsThenThePointers() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let straddling = CGRect(x: 1300, y: 100, width: 800, height: 600)
        XCTAssertEqual(SummonPlacement.screen(frames: screens, focusedWindow: straddling, pointer: .zero), 1)
        XCTAssertEqual(SummonPlacement.screen(frames: screens, focusedWindow: nil, pointer: CGPoint(x: 2000, y: 500)), 1)
        XCTAssertEqual(SummonPlacement.screen(frames: screens, focusedWindow: CGRect(x: 9000, y: 0, width: 10, height: 10), pointer: CGPoint(x: 10, y: 10)), 0)
        XCTAssertEqual(SummonPlacement.screen(frames: screens, focusedWindow: nil, pointer: CGPoint(x: -50, y: -50)), 0)
        XCTAssertEqual(SummonPlacement.cocoaRect(quartz: CGRect(x: 100, y: 50, width: 800, height: 600), primaryHeight: 900),
                       CGRect(x: 100, y: 250, width: 800, height: 600))
    }

    func testThePositionDefaultsToTheMainDisplay() {
        XCTAssertEqual(SummonPosition(rawValue: "nonsense"), nil)
        XCTAssertEqual(SummonPosition.allCases.map(\.rawValue), ["mainDisplay", "currentDisplay", "currentWindow"])
    }
}
