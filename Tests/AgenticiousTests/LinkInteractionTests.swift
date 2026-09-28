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
}
