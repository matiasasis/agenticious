import XCTest
import AppKit
@testable import Agenticious

final class LinkInteractionTests: XCTestCase {
    @MainActor
    func testMarkdownPreservesLinksAndFormatting() async {
        let text = LinkedMarkdownText.attributedText("Plain **bold** and [PR #42](https://github.com/team/repo/pull/42).")
        XCTAssertEqual(text.string, "Plain bold and PR #42.")
        let link = (text.string as NSString).range(of: "PR #42")
        XCTAssertEqual(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL, URL(string: "https://github.com/team/repo/pull/42"))
        XCTAssertTrue(text.attribute(.cursor, at: link.location, effectiveRange: nil) as? NSCursor === NSCursor.pointingHand)
        XCTAssertNil(text.attribute(.cursor, at: 0, effectiveRange: nil))
        let bold = (text.string as NSString).range(of: "bold")
        let font = text.attribute(.font, at: bold.location, effectiveRange: nil) as! NSFont
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
    }

    @MainActor
    func testOnlyWrappedLinkRangesGetHandCursorRects() async {
        let view = LinkTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 300))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.containerSize = NSSize(width: 140, height: 1000)
        view.textStorage?.setAttributedString(LinkedMarkdownText.attributedText("Plain text\n[Long pull request link wrapping across several lines](https://github.com/team/repo/pull/42)"))
        let rects = view.linkRects()
        XCTAssertTrue(rects.count > 1)
        XCTAssertFalse(rects.contains { $0.contains(NSPoint(x: 4, y: 4)) })
        view.textStorage?.setAttributedString(LinkedMarkdownText.attributedText("No links here"))
        XCTAssertTrue(view.linkRects().isEmpty)
    }

    @MainActor
    func testCursorRegistrationClipsLinksAndRejectsInvisibleOrInvalidAreas() async {
        let view = CursorRecordingView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.addVisibleLinkCursor(for: NSRect(x: 10, y: 90, width: 80, height: 30))
        XCTAssertEqual(view.registeredRects, [NSRect(x: 10, y: 90, width: 80, height: 10)])
        view.registeredRects = []
        for rect in [NSRect(x: 0, y: 200, width: 80, height: 20),
                     NSRect(x: 0, y: 100, width: 80, height: 20), .zero, .null,
                     NSRect(x: CGFloat.nan, y: 0, width: 10, height: 10)] {
            view.addVisibleLinkCursor(for: rect)
        }
        XCTAssertTrue(view.registeredRects.isEmpty)
    }

    @MainActor
    func testCursorResetWhileScrollingAndResizingLinkedText() async {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 140, height: 60))
        let view = LinkTextView(frame: NSRect(x: 0, y: 0, width: 140, height: 1000))
        view.isVerticallyResizable = false
        view.textStorage?.setAttributedString(LinkedMarkdownText.attributedText(
            (0..<20).map { "Plain text \($0)\n[Pull request \($0)](https://example.com/pull/\($0))" }.joined(separator: "\n")))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil }
        for width: CGFloat in [140, 90, 240] {
            scroll.setFrameSize(NSSize(width: width, height: 60))
            view.setFrameSize(NSSize(width: width, height: 1000))
            for offset: CGFloat in [0, 150, 600, 0] {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                XCTAssertTrue(view.linkRects().contains { $0.intersection(view.visibleRect).isNull })
                view.resetCursorRects()
            }
        }
    }

    @MainActor
    func testFittingSizeHugsShortTextAndWrapsLongTextAtTheGivenWidth() async {
        let view = LinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(LinkedMarkdownText.attributedText("Go ahead."))
        let short = view.fittingSize(width: 400)!
        view.textStorage?.setAttributedString(LinkedMarkdownText.attributedText(String(repeating: "A long reply that wraps. ", count: 20)))
        let long = view.fittingSize(width: 400)!
        XCTAssertLessThan(short.width, 100)
        XCTAssertGreaterThan(long.width, 300)
        XCTAssertLessThanOrEqual(long.width, 400)
        XCTAssertGreaterThan(long.height, short.height)
    }

}


@MainActor
private final class CursorRecordingView: NSView {
    var registeredRects: [NSRect] = []

    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        registeredRects.append(rect)
        super.addCursorRect(rect, cursor: cursor)
    }
}
