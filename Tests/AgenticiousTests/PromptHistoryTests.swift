import AppKit
import SwiftUI
import XCTest
@testable import Agenticious

final class PromptHistoryTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("prompt-history.json") }
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testProjectsWithTheSameNameAndNoProjectHaveIndependentHistory() {
        let first = Project(path: "/work/app")
        let second = Project(path: "/personal/app")
        let history = PromptHistory(url: url)
        history.record("Shared input", for: "custom", in: first)
        history.record("First project only", for: "custom", in: first)
        history.record("Shared input", for: "custom", in: second)
        history.record("Unfiled", for: "custom", in: .none)
        history.remove("Shared input", for: "custom", in: first)

        let reopened = PromptHistory(url: url)
        XCTAssertEqual(reopened.recent(for: "custom", in: first).map(\.text), ["First project only"])
        XCTAssertEqual(reopened.recent(for: "custom", in: second).map(\.text), ["Shared input"])
        XCTAssertEqual(reopened.recent(for: "custom", in: .none).map(\.text), ["Unfiled"])
    }

    @MainActor
    func testInputsAreSavedPerPresetMostRecentFirstAndSurviveRelaunch() {
        let history = PromptHistory(url: url)
        history.record("Fix the flaky login spec", for: "fixCI", in: .none, at: start)
        history.record("Review #123", for: "reviewPR", in: .none, at: start.addingTimeInterval(60))
        history.record("Speed up the nightly build", for: "fixCI", in: .none, at: start.addingTimeInterval(120))

        let relaunched = PromptHistory(url: url)
        XCTAssertEqual(relaunched.recent(for: "fixCI", in: .none).map(\.text), ["Speed up the nightly build", "Fix the flaky login spec"])
        XCTAssertEqual(relaunched.recent(for: "reviewPR", in: .none).map(\.text), ["Review #123"])
        XCTAssertEqual(relaunched.recent(for: "reviewPR", in: .none).first?.usedAt, start.addingTimeInterval(60))
        XCTAssertEqual(relaunched.recent(for: "custom", in: .none), [])
    }

    @MainActor
    func testTheSameInputUsedAgainMovesToTheTopInsteadOfRepeating() {
        let history = PromptHistory(url: url)
        history.record("Fix the flaky login spec", for: "fixCI", in: .none, at: start)
        history.record("Speed up the nightly build", for: "fixCI", in: .none, at: start.addingTimeInterval(60))
        history.record("  Fix the flaky login spec\n", for: "fixCI", in: .none, at: start.addingTimeInterval(120))

        let recent = PromptHistory(url: url).recent(for: "fixCI", in: .none)
        XCTAssertEqual(recent.map(\.text), ["Fix the flaky login spec", "Speed up the nightly build"])
        XCTAssertEqual(recent.first?.usedAt, start.addingTimeInterval(120))
    }

    @MainActor
    func testInputsAreTrimmedAndEmptyOnesAreNotSaved() {
        let history = PromptHistory(url: url)
        history.record("   \n\t ", for: "custom", in: .none, at: start)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        history.record("\n  Tidy the README  \n", for: "custom", in: .none, at: start)
        XCTAssertEqual(PromptHistory(url: url).recent(for: "custom", in: .none).map(\.text), ["Tidy the README"])
    }

    @MainActor
    func testTwentyAreKeptPerPresetAndFiveAreShown() {
        let history = PromptHistory(url: url)
        for index in 1...25 { history.record("Task \(index)", for: "custom", in: .none, at: start.addingTimeInterval(Double(index))) }
        let relaunched = PromptHistory(url: url)
        XCTAssertEqual(relaunched.recent(for: "custom", in: .none, limit: .max).map(\.text), (6...25).reversed().map { "Task \($0)" })
        XCTAssertEqual(relaunched.recent(for: "custom", in: .none).map(\.text), ["Task 25", "Task 24", "Task 23", "Task 22", "Task 21"])
    }

    /// The order is the order of use: a clock set back mustn't reshuffle it.
    @MainActor
    func testOrderFollowsUseNotTimestamps() {
        let history = PromptHistory(url: url)
        history.record("First", for: "custom", in: .none, at: start)
        history.record("Second", for: "custom", in: .none, at: start.addingTimeInterval(-3600))
        history.record("Third", for: "custom", in: .none, at: start.addingTimeInterval(-7200))
        XCTAssertEqual(PromptHistory(url: url).recent(for: "custom", in: .none).map(\.text), ["Third", "Second", "First"])
    }

    @MainActor
    func testRemovingAnInputIsSavedAndLeavesTheOthers() {
        let history = PromptHistory(url: url)
        history.record("Review #123", for: "reviewPR", in: .none, at: start)
        history.record("Review #124", for: "reviewPR", in: .none, at: start)
        history.record("Review #124", for: "custom", in: .none, at: start)
        history.remove("Review #124", for: "reviewPR", in: .none)

        XCTAssertEqual(history.recent(for: "reviewPR", in: .none).map(\.text), ["Review #123"])
        let relaunched = PromptHistory(url: url)
        XCTAssertEqual(relaunched.recent(for: "reviewPR", in: .none).map(\.text), ["Review #123"])
        XCTAssertEqual(relaunched.recent(for: "custom", in: .none).map(\.text), ["Review #124"])
    }

    @MainActor
    func testAnUnreadableFileIsNoHistoryAndIsReplacedOnTheNextSave() throws {
        try Data("not json".utf8).write(to: url)
        let history = PromptHistory(url: url)
        XCTAssertEqual(history.recent(for: "custom", in: .none), [])
        history.record("Tidy the README", for: "custom", in: .none, at: start)
        XCTAssertEqual(PromptHistory(url: url).recent(for: "custom", in: .none).map(\.text), ["Tidy the README"])
    }

    @MainActor
    func testASaveThatFailsKeepsTheInputForThisRunWithoutThrowing() throws {
        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        let history = PromptHistory(url: blocked.appendingPathComponent("prompt-history.json"))
        history.record("Tidy the README", for: "custom", in: .none, at: start)
        XCTAssertEqual(history.recent(for: "custom", in: .none).map(\.text), ["Tidy the README"])
    }

    @MainActor
    func testDeletedPresetsLoseTheirHistoryOnTheNextLoadOrSave() throws {
        var presets: Set<String>? = ["custom", "fixCI", "reviewPR"]
        let history = PromptHistory(url: url) { presets }
        history.record("Fix the flaky login spec", for: "fixCI", in: .none, at: start)
        history.record("Review #123", for: "reviewPR", in: .none, at: start)

        presets = ["custom", "reviewPR"]
        XCTAssertEqual(PromptHistory(url: url) { presets }.recent(for: "fixCI", in: .none), [], "dropped on load")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("flaky"), "still in the file until a save")

        history.record("Tidy the README", for: "custom", in: .none, at: start)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("flaky"), "dropped on save")
        XCTAssertEqual(PromptHistory(url: url).recent(for: "reviewPR", in: .none).map(\.text), ["Review #123"])

        // While the presets are unknown (their file didn't load), nothing is dropped on a guess.
        presets = nil
        XCTAssertEqual(PromptHistory(url: url) { presets }.recent(for: "reviewPR", in: .none).map(\.text), ["Review #123"])
    }

    func testAgeIsShortAndNamesYesterday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 18, hour: 15)))
        func age(_ seconds: TimeInterval) -> String { PromptHistoryLog.age(of: now.addingTimeInterval(-seconds), now: now, calendar: calendar) }
        XCTAssertEqual(age(-30), "Just now")
        XCTAssertEqual(age(20), "Just now")
        XCTAssertEqual(age(5 * 60), "5 min ago")
        XCTAssertEqual(age(2 * 3600), "2 h ago")
        XCTAssertEqual(age(14 * 3600), "14 h ago")
        XCTAssertEqual(age(20 * 3600), "Yesterday")
        XCTAssertEqual(age(3 * 86400), "3 days ago")
        XCTAssertFalse(age(30 * 86400).contains("ago"))
    }

    func testFiveBoxesGoAcrossOrSplitIntoEvenRows() {
        let layout = RecentInputsLayout(minimumWidth: RecentInputsRow.boxWidth)
        XCTAssertEqual(layout.columns(for: 912), 5)
        XCTAssertEqual(layout.columns(for: 672), 3, "3 + 2, not 4 + 1")
        XCTAssertEqual(layout.columns(for: 290), 2)
        XCTAssertEqual(layout.columns(for: 100), 1)
        XCTAssertEqual(RecentInputsLayout(minimumWidth: RecentInputsRow.boxWidth * 1.5).columns(for: 672), 3)
    }

    @MainActor
    func testUsingARecentInputIsOneEditThatUndoBringsBackWhatWasTyped() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let owner = UndoOwner(undo)
        let textView = NSTextView()
        textView.allowsUndo = true
        textView.delegate = owner
        undo.beginUndoGrouping()
        textView.insertText("Half-typed draft", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: textView, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        textView.replaceAllUndoably(with: "Fix the flaky login spec\n```\nexpect(page).to be_ok\n```")
        XCTAssertEqual(textView.string, "Fix the flaky login spec\n```\nexpect(page).to be_ok\n```")
        XCTAssertEqual(changes, 1, "the sheet's binding hears about it as it does about typing")
        XCTAssertEqual(textView.selectedRange().location, (textView.string as NSString).length)
        XCTAssertEqual(undo.undoActionName, "Use Recent Input")

        undo.undo()
        XCTAssertEqual(textView.string, "Half-typed draft")
        undo.redo()
        XCTAssertEqual(textView.string, "Fix the flaky login spec\n```\nexpect(page).to be_ok\n```")
    }

    /// Off screen at the narrowest and usual sheet widths, at 100% and 150%: nothing is drawn outside the row's width,
    /// a long multi-line input takes no more room than a one-line one (three lines are kept for each), and five boxes
    /// take at most two rows. Set RECENT_INPUTS_SNAPSHOT_DIR to keep the PNGs.
    @MainActor
    func testRowStaysWithinTheSheetAndEachBoxWithinItsLines() throws {
        let long = "Fix the flaky login spec. It fails about one run in ten on CI with a timeout.\n```ruby\nexpect(page).to have_content(\"Welcome\")\n```\nKeep the retry out of it; find the race instead."
        let others = ["Review #123", "Implement the export button on the reports page so admins can download a CSV of the current filters",
                      "Why does the cache miss on every second request after deploy?", "Tidy the README"]
        let padding: CGFloat = 24
        for sheet in [720.0, 960.0] {
            let width = sheet - 48
            for scale in [1.0, 1.5] {
                func render(_ texts: [String], name: String) throws -> CGFloat {
                    let inputs = texts.enumerated().map { RecentInput(text: $1, usedAt: start.addingTimeInterval(-Double($0) * 7200)) }
                    let row = RecentInputsRow(inputs: inputs, now: start, use: { _ in }, remove: { _ in })
                        .frame(width: width).padding(padding).background(AgenticiousStyle.ink)
                        .environment(\.textScale, scale).preferredColorScheme(.dark)
                    let view = NSHostingView(rootView: row)
                    view.frame.size = view.fittingSize
                    XCTAssertEqual(view.frame.width, width + padding * 2)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let ink = try XCTUnwrap(bitmap.colorAt(x: 1, y: 1))
                    // The middle of the padding either side, in pixels.
                    let margin = Int(padding / 2 * CGFloat(bitmap.pixelsWide) / view.frame.width)
                    for x in [margin, bitmap.pixelsWide - 1 - margin] {
                        let drawn = (0..<bitmap.pixelsHigh).filter { bitmap.colorAt(x: x, y: $0) != ink }
                        XCTAssertEqual(drawn, [], "\(name): drawn outside the row at x \(x)")
                    }
                    if let dir = ProcessInfo.processInfo.environment["RECENT_INPUTS_SNAPSHOT_DIR"] {
                        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
                    }
                    return view.frame.height
                }
                let label = "\(Int(sheet))-\(Int(scale * 100))"
                let short = try render(["Review #123"], name: "\(label)-1-short")
                XCTAssertEqual(try render([long], name: "\(label)-1"), short, "\(label): a long input is cut at three lines")
                _ = try render([long] + others.prefix(2), name: "\(label)-3")
                let five = try render([long] + others, name: "\(label)-5")
                XCTAssertLessThanOrEqual(five, short * 2, "\(label): five boxes take at most two rows")
            }
        }
    }
}

private final class UndoOwner: NSObject, NSTextViewDelegate {
    let undo: UndoManager
    init(_ undo: UndoManager) { self.undo = undo }
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}
