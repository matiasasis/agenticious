import XCTest
@testable import Agenticious

final class SnippetEditorTests: XCTestCase {
    func testThirdBacktickOnAnEmptyLineAddsTheClosingFence() throws {
        let text = "Fix this:\n``"
        let completion = try XCTUnwrap(SnippetFences.completion(in: text, typingBacktickAt: NSRange(location: 12, length: 0)))
        XCTAssertEqual(completion.insertion, "`\n```")
        XCTAssertEqual(completion.cursor, 13)
    }

    func testClosingFenceAndMidLineBackticksAreTypedAsIs() {
        let inside = "```\nlet a = 1\n``"
        XCTAssertNil(SnippetFences.completion(in: inside, typingBacktickAt: NSRange(location: 16, length: 0)))
        let midLine = "run ``"
        XCTAssertNil(SnippetFences.completion(in: midLine, typingBacktickAt: NSRange(location: 6, length: 0)))
    }

    func testFencedBlocksAndInlineCodeAreStyledAsCode() {
        let text = "Use `make`\n```swift\nlet a = 1\n```\nDone"
        let styles = SnippetFences.styles(in: text)
        let string = text as NSString
        XCTAssertEqual(styles.code.map(string.substring(with:)), ["`make`", "```swift\nlet a = 1\n```"])
        XCTAssertEqual(styles.fences.map(string.substring(with:)), ["```swift", "```"])
    }

    func testSnippetsAreLeftOutOfTaskTitles() {
        let custom = TaskTemplate.custom
        XCTAssertEqual(custom.title(for: "Fix this crash\n```\nFatal error: nil\n```"), "Fix this crash")
        XCTAssertEqual(custom.title(for: "```\nonly code\n```"), custom.name)
    }
}
