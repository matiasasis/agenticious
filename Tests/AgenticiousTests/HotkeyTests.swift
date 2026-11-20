import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Agenticious

final class HotkeyTests: XCTestCase {
    private let controlOptionR = Hotkey(keyCode: 15, modifiers: [.control, .option], key: "R")

    func testKeyPressBecomesAShortcutShownInMenuOrder() throws {
        let all = try XCTUnwrap(Hotkey(keyCode: 15, flags: [.command, .shift, .option, .control, .capsLock], characters: "r"))
        XCTAssertEqual(all.display, "⌃⌥⇧⌘R")
        XCTAssertEqual(all.carbonModifiers, UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(Hotkey(keyCode: UInt16(kVK_Space), flags: .option, characters: " ")?.display, "⌥Space")
        XCTAssertEqual(Hotkey(keyCode: UInt16(kVK_LeftArrow), flags: .control, characters: "\u{F702}")?.display, "⌃←")
        XCTAssertEqual(Hotkey(keyCode: UInt16(kVK_F5), flags: [], characters: "\u{F708}")?.display, "F5")
        XCTAssertNil(Hotkey(keyCode: 200, flags: .command, characters: "\u{F8FF}"))
        XCTAssertNil(Hotkey(keyCode: 200, flags: .command, characters: nil))
        // "ß" uppercases to two characters; the key keeps its own name.
        XCTAssertEqual(Hotkey(keyCode: 27, flags: [.control, .option], characters: "ß")?.display, "⌃⌥ß")
    }

    func testShortcutMustNotTakeTypingOrStandardShortcutsFromEveryApp() {
        XCTAssertNotNil(Hotkey(keyCode: 15, modifiers: [], key: "R").problem)
        XCTAssertNotNil(Hotkey(keyCode: 15, modifiers: [.shift], key: "R").problem)
        XCTAssertNil(Hotkey(keyCode: UInt32(kVK_F5), modifiers: [], key: "F5").problem)
        XCTAssertNil(controlOptionR.problem)
        XCTAssertNotNil(Hotkey(keyCode: 9, modifiers: [.command], key: "V").problem)
        XCTAssertNotNil(Hotkey(keyCode: 6, modifiers: [.shift, .command], key: "Z").problem)
        XCTAssertNotNil(Hotkey(keyCode: UInt32(kVK_Return), modifiers: [.command], key: "↩").problem)
        XCTAssertNil(Hotkey(keyCode: 9, modifiers: [.control, .command], key: "V").problem)
        for key in ["S", "N", "Q", ",", "Space"] { XCTAssertNotNil(Hotkey(keyCode: 1, modifiers: [.command], key: key).problem, key) }
        XCTAssertNil(Hotkey(keyCode: 1, modifiers: [.shift, .command], key: "S").problem)
    }

    func testShortcutsClashOnKeyAndModifiersWhateverTheirOrderOrLabel() {
        XCTAssertTrue(controlOptionR.matches(Hotkey(keyCode: 15, modifiers: [.option, .control], key: "P")))
        XCTAssertFalse(controlOptionR.matches(Hotkey(keyCode: 15, modifiers: [.control], key: "R")))
        XCTAssertFalse(controlOptionR.matches(Hotkey(keyCode: 14, modifiers: [.control, .option], key: "R")))
    }

    func testFirstPresetKeepsASharedShortcutAndTheOthersSayWhy() {
        let presets = [
            TaskTemplate(id: "review", name: "Review PR", hotkey: controlOptionR),
            TaskTemplate(id: "plain", name: "Plain"),
            TaskTemplate(id: "implement", name: "Implement", hotkey: Hotkey(keyCode: 15, modifiers: [.option, .control], key: "R")),
            TaskTemplate(id: "bare", name: "Bare", hotkey: Hotkey(keyCode: 15, modifiers: [], key: "R")),
        ]
        let plan = HotkeyPlan(presets: presets)
        XCTAssertEqual(plan.bindings, [.init(hotkey: controlOptionR, presetID: "review")])
        XCTAssertEqual(plan.problems["implement"], "Review PR already uses ⌃⌥R.")
        XCTAssertNotNil(plan.problems["bare"])
        XCTAssertEqual(Set(plan.problems.keys), ["implement", "bare"])
    }

    func testEditorAgreesWithTheCardsAboutWhoKeepsASharedShortcut() {
        let review = TaskTemplate(id: "review", name: "Review PR", hotkey: controlOptionR)
        let implement = TaskTemplate(id: "implement", name: "Implement", hotkey: controlOptionR)
        let plain = TaskTemplate(id: "plain", name: "Plain")
        // A hand-edited file where two presets share a shortcut: the first keeps it, and can still be edited.
        let saved = [review, implement, plain]
        XCTAssertNil(HotkeyPlan(presets: saved, editing: review).problems["review"])
        XCTAssertEqual(HotkeyPlan(presets: saved, editing: implement).problems["implement"], "Review PR already uses ⌃⌥R.")
        // Newly recorded on another preset, even one earlier in the order, it stays with its owner.
        var first = TaskTemplate(id: "first", name: "First")
        first.hotkey = controlOptionR
        XCTAssertEqual(HotkeyPlan(presets: [TaskTemplate(id: "first", name: "First"), review], editing: first).problems["first"],
                       "Review PR already uses ⌃⌥R.")
        var new = plain
        new.id = "new"
        new.hotkey = Hotkey(keyCode: 17, modifiers: [.control, .option], key: "T")
        XCTAssertNil(HotkeyPlan(presets: saved, editing: new).problems["new"])
    }

    @MainActor
    func testPresetsSavedBeforeShortcutsLoadAndAShortcutSurvivesRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("task-presets.json")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defer { defaults.removePersistentDomain(forName: #function) }

        let store = TaskPresetStore(url: url, defaults: defaults)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("hotkey"))
        XCTAssertTrue(store.presets.allSatisfy { $0.hotkey == nil })

        var review = store.preset(id: "reviewPR")
        review.hotkey = controlOptionR
        try store.save(review)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let hotkey = try XCTUnwrap(saved.first { $0["id"] as? String == "reviewPR" }?["hotkey"] as? [String: Any])
        XCTAssertEqual(hotkey["keyCode"] as? Int, 15)
        XCTAssertEqual(hotkey["modifiers"] as? [String], ["control", "option"])
        XCTAssertEqual(hotkey["key"] as? String, "R")

        let relaunched = TaskPresetStore(url: url, defaults: defaults)
        XCTAssertNil(relaunched.loadError)
        XCTAssertEqual(relaunched.preset(id: "reviewPR").hotkey, controlOptionR)
    }

    func testFloatingWindowUsesTheLastWorkspaceWhateverAgentIsSelected() {
        let favorites = [Project(path: "/code/app"), Project(path: "/code/site")]
        XCTAssertEqual(SessionStore.lastUsedProject(path: "/code/site", favorites: favorites), favorites[1])
        XCTAssertEqual(SessionStore.lastUsedProject(path: "", favorites: favorites), .none)
        XCTAssertEqual(SessionStore.lastUsedProject(path: "/code/removed", favorites: favorites), favorites[0])
        XCTAssertEqual(SessionStore.lastUsedProject(path: nil, favorites: favorites), favorites[0])
        XCTAssertEqual(SessionStore.lastUsedProject(path: nil, favorites: []), .none)
    }

    func testSummonPanelFlagNamesAPresetOrDefaultsToTheCustomTask() {
        XCTAssertEqual(LaunchOptions(arguments: ["app", "--summon-panel", "reviewPR"]).summonPanelTemplate, "reviewPR")
        XCTAssertEqual(LaunchOptions(arguments: ["app", "--summon-panel"]).summonPanelTemplate, "custom")
        XCTAssertEqual(LaunchOptions(arguments: ["app", "--summon-panel", "--snapshot-dir", "/tmp/x"]).summonPanelTemplate, "custom")
        XCTAssertNil(LaunchOptions(arguments: ["app"]).summonPanelTemplate)
        XCTAssertEqual(LaunchOptions(arguments: ["app", "--new-agent", "fixCI"]).newAgentTemplate, "fixCI")
        XCTAssertNil(LaunchOptions(arguments: ["app", "--summon-panel"]).newAgentTemplate)
    }
}
