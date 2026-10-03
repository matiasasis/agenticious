import XCTest
@testable import Agenticious

final class MarkdownBlocksTests: XCTestCase {
    func testHeadingsParagraphsAndRules() {
        let blocks = MarkdownBlocks.parse("## Pause agent\nIt keeps the **worktree**.\nResume continues.\n\n---\n### Use C# ##\n#hashtag")
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Pause agent"),
            .paragraph("It keeps the **worktree**.\nResume continues."),
            .rule,
            .heading(level: 3, text: "Use C#"),
            .paragraph("#hashtag"),
        ])
    }

    func testPipeTablesWithAlignmentEscapesAndShortRows() {
        let text = """
        Compare:
        | | Process | `a|b` |
        |---|:---:|--:|
        | **Pause** | stopped \\| kept | x |
        | End | removed |
        After
        """
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .paragraph("Compare:"),
            .table(MarkdownTable(header: ["", "Process", "`a|b`"], alignments: [.leading, .center, .trailing],
                                 rows: [["**Pause**", "stopped | kept", "x"], ["End", "removed", ""]])),
            .paragraph("After"),
        ])
    }

    func testTableWithoutHeaderRow() {
        let text = "|---|---|:-:|\n| Pause | stopped | yes |\n| End agent | removed (like Archive) | no |\nAfter"
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .table(MarkdownTable(header: [], alignments: [.leading, .leading, .center],
                                 rows: [["Pause", "stopped", "yes"], ["End agent", "removed (like Archive)", "no"]])),
            .paragraph("After"),
        ])
        XCTAssertEqual(MarkdownBlocks.parse("---|---"), [.paragraph("---|---")])
    }

    func testPipesWithoutDelimiterRowStayText() {
        XCTAssertEqual(MarkdownBlocks.parse("a | b\nc | d"), [.paragraph("a | b\nc | d")])
    }

    func testBoxDrawnAndAsciiTablesStayMonospacedAsTyped() {
        let box = "┌────┬────┐\n│ a  │ b  │\n└────┴────┘"
        let ascii = "+---+---+\n| a | b |\n+---+---+"
        XCTAssertEqual(MarkdownBlocks.parse("Before\n\(box)\nAfter\n\n\(ascii)"), [
            .paragraph("Before"), .diagram(box), .paragraph("After"), .diagram(ascii),
        ])
        let tree = "Sources\n├── App.swift\n│   ▼\n└── Views"
        XCTAssertEqual(MarkdownBlocks.parse(tree), [.paragraph("Sources"), .diagram("├── App.swift\n│   ▼\n└── Views")])
    }

    func testFencedCodeKeepsMarkdownLiteralAndToleratesMissingClose() {
        XCTAssertEqual(MarkdownBlocks.parse("Run `a```b`:\n```swift\n## not a heading\n| a |\n```\nDone\n~~~\nopen"), [
            .paragraph("Run `a```b`:"), .code("## not a heading\n| a |"), .paragraph("Done"), .code("open"),
        ])
    }

    func testListsQuotesAndContinuations() {
        let text = "- one\n  wrapped\n- two\n\n  1. nested\n\nAfter\n> quoted\n> more"
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .list([
                MarkdownListItem(depth: 0, marker: "•", text: "one\nwrapped"),
                MarkdownListItem(depth: 0, marker: "•", text: "two"),
                MarkdownListItem(depth: 1, marker: "1.", text: "nested"),
            ]),
            .paragraph("After"),
            .quote("quoted\nmore"),
        ])
    }
}
