import SwiftUI
import XCTest
@testable import Agenticious

/// Payloads shaped like Claude Code's PermissionRequest hook, with made-up contents.
enum PermissionFixture {
    static let touch: [String: Any] = [
        "tool_name": "Bash", "tool_input": ["command": "touch build/ready", "description": "Mark the build ready"], "cwd": "/code/app",
        "permission_suggestions": [["type": "setMode", "mode": "acceptEdits", "destination": "session"]],
    ]
    static let script: [String: Any] = [
        "tool_name": "Bash", "tool_input": ["command": "python3 -c \"print(11)\""],
        "permission_suggestions": [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "python3 -c \"print(11)\""]],
                                    "behavior": "allow", "destination": "localSettings"]],
    ]
    static let read: [String: Any] = [
        "tool_name": "Read", "tool_input": ["file_path": "/etc/hosts"],
        "permission_suggestions": [
            ["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "//etc/**"]], "behavior": "allow", "destination": "session"],
            ["type": "addRules", "rules": [["toolName": "Read", "ruleContent": "//private/etc/**"]], "behavior": "allow", "destination": "session"],
        ],
    ]
    static var subagentTouch: [String: Any] { touch.merging(["agent_id": "a1", "agent_type": "general-purpose"]) { $1 } }

    static func request(_ tool: String, _ input: [String: Any], suggestions: [[String: Any]]? = nil) -> PermissionRequest {
        var payload: [String: Any] = ["tool_name": tool, "tool_input": input]
        payload["permission_suggestions"] = suggestions
        return PermissionRequest.parse(payload)!
    }

    static func decision(_ reply: Data?) -> [String: Any]? {
        let json = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (json?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
    }
}

final class AgentPermissionTests: XCTestCase {
    private typealias Fixture = PermissionFixture
    private let allow = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#

    func testOnlyRequestsTheCardCanAnswerAreParsed() throws {
        for tool in ["AskUserQuestion", "ExitPlanMode", "EnterPlanMode", "mcp__agenticious__set_plan"] {
            XCTAssertNil(PermissionRequest.parse(["tool_name": tool, "tool_input": [String: Any]()]), tool)
        }
        XCTAssertNil(PermissionRequest.parse(["tool_name": "Bash"]), "no input to show")
        XCTAssertNil(PermissionRequest.parse(["tool_name": "", "tool_input": ["command": "ls"]]))
        XCTAssertNil(PermissionRequest.parse([:]))

        let main = try XCTUnwrap(PermissionRequest.parse(Fixture.touch))
        XCTAssertEqual(main.toolName, "Bash")
        XCTAssertEqual(main.directory, "/code/app")
        XCTAssertFalse(main.isFromSubagent)
        XCTAssertNil(main.toolUseID)
        let subagent = try XCTUnwrap(PermissionRequest.parse(Fixture.subagentTouch))
        XCTAssertEqual(subagent.agentID, "a1")
        XCTAssertEqual(subagent.agentType, "general-purpose")
        XCTAssertTrue(subagent.isFromSubagent)
        XCTAssertFalse(try XCTUnwrap(PermissionRequest.parse(Fixture.touch.merging(["agent_id": ""]) { $1 })).isFromSubagent)
    }

    func testAnEmptySuggestionListOnACommandMeansAWarningOnlyTheTerminalShows() {
        XCTAssertTrue(Fixture.request("Bash", ["command": "ls"], suggestions: []).hasTerminalOnlyWarning)
        XCTAssertFalse(Fixture.request("Bash", ["command": "ls"]).hasTerminalOnlyWarning, "no list at all")
        XCTAssertFalse(PermissionRequest.parse(Fixture.touch)!.hasTerminalOnlyWarning)
        XCTAssertFalse(Fixture.request("Write", ["file_path": "/code/app/a.txt", "content": ""], suggestions: []).hasTerminalOnlyWarning)
    }

    func testAllowIsExactlyTheJSONClaudeCodeAccepts() throws {
        let request = try XCTUnwrap(PermissionRequest.parse(Fixture.script))
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.hookReply(for: .allow)), as: UTF8.self), allow)
        // A request with nothing safe to remember answers "don't ask again" as a plain allow.
        let touch = try XCTUnwrap(PermissionRequest.parse(Fixture.touch))
        XCTAssertEqual(String(decoding: try XCTUnwrap(touch.hookReply(for: .allowAlways)), as: UTF8.self), allow)
    }

    func testDoNotAskAgainEchoesClaudesSuggestionsUntouched() throws {
        let request = try XCTUnwrap(PermissionRequest.parse(Fixture.script))
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.hookReply(for: .allowAlways)), as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow","updatedPermissions":[{"behavior":"allow","destination":"localSettings","#
                       + #""rules":[{"ruleContent":"python3 -c \"print(11)\"","toolName":"Bash"}],"type":"addRules"}]},"hookEventName":"PermissionRequest"}}"#)
        let read = try XCTUnwrap(PermissionRequest.parse(Fixture.read))
        let echoed = try XCTUnwrap(Fixture.decision(read.hookReply(for: .allowAlways))?["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(echoed as NSArray, Fixture.read["permission_suggestions"] as? NSArray)
    }

    func testDenyStopsTheMainAgentUnlessANoteSaysWhatToDoInstead() throws {
        let request = try XCTUnwrap(PermissionRequest.parse(Fixture.script))
        XCTAssertEqual(String(decoding: try XCTUnwrap(request.hookReply(for: .deny(note: " \n"))), as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"deny","interrupt":true,"message":"The user denied this tool use in Agenticious."},"#
                       + #""hookEventName":"PermissionRequest"}}"#)
        XCTAssertTrue(request.stopsTurn(.deny(note: "")))

        let noted = try XCTUnwrap(Fixture.decision(request.hookReply(for: .deny(note: "  use uv instead\n"))))
        XCTAssertEqual(noted["behavior"] as? String, "deny")
        XCTAssertNil(noted["interrupt"])
        XCTAssertEqual(noted["message"] as? String,
                       "The user doesn't want to proceed with this tool use. The tool use was rejected. To tell you how to proceed, the user said:\nuse uv instead")
        XCTAssertFalse(request.stopsTurn(.deny(note: "use uv instead")))
        XCTAssertFalse(request.stopsTurn(.allow))

        // What an interrupt does inside a subagent is unknown, so it is never sent there.
        let subagent = try XCTUnwrap(PermissionRequest.parse(Fixture.subagentTouch))
        let denied = try XCTUnwrap(Fixture.decision(subagent.hookReply(for: .deny(note: ""))))
        XCTAssertNil(denied["interrupt"])
        XCTAssertEqual(denied["message"] as? String, "The user denied this tool use in Agenticious.")
        XCTAssertFalse(subagent.stopsTurn(.deny(note: "")))

        let long = Fixture.decision(request.hookReply(for: .deny(note: String(repeating: "n", count: 5_000))))?["message"] as? String
        XCTAssertEqual(long, PermissionRequest.denyMessage(note: String(repeating: "n", count: 2_000)), "a note is cut at 2000 characters")
    }

    func testNoReplyEverRewritesWhatRuns() throws {
        for payload in [Fixture.touch, Fixture.script, Fixture.read, Fixture.subagentTouch] {
            let request = try XCTUnwrap(PermissionRequest.parse(payload))
            for decision in [PermissionDecision.allow, .allowAlways, .deny(note: ""), .deny(note: "not this")] {
                let body = try XCTUnwrap(Fixture.decision(request.hookReply(for: decision)))
                XCTAssertNil(body["updatedInput"])
                XCTAssertTrue(Set(body.keys).isSubset(of: ["behavior", "message", "interrupt", "updatedPermissions"]))
            }
        }
    }

    func testDoNotAskAgainIsOfferedOnlyForAllowRulesKeptToThisSessionOrFolder() {
        func offer(_ suggestions: [[String: Any]]) -> PermissionRequest.AlwaysAllow? {
            Fixture.request("Bash", ["command": "ls"], suggestions: suggestions).alwaysAllow
        }
        func rule(_ destination: String, behavior: String = "allow", type: String = "addRules") -> [String: Any] {
            ["type": type, "rules": [["toolName": "Bash", "ruleContent": "ls"]], "behavior": behavior, "destination": destination]
        }
        XCTAssertEqual(offer([rule("session")]), .init(rules: ["Bash(ls)"], scope: "for this session"))
        XCTAssertEqual(offer([rule("localSettings")])?.scope, "saved in this folder's .claude/settings.local.json")
        XCTAssertEqual(PermissionRequest.parse(Fixture.read)?.alwaysAllow,
                       .init(rules: ["Read(//etc/**)", "Read(//private/etc/**)"], scope: "for this session"), "two rules, one choice")
        XCTAssertNil(offer([rule("session"), rule("localSettings")]), "one sentence can't say which rule is kept where")
        XCTAssertEqual(offer([["type": "addRules", "rules": [["toolName": "WebSearch"]], "behavior": "allow", "destination": "session"]])?.rules, ["WebSearch"])

        XCTAssertNil(offer([]))
        XCTAssertNil(PermissionRequest.parse(Fixture.touch)?.alwaysAllow, "a mode change")
        XCTAssertNil(offer([["type": "addDirectories", "directories": ["/code/app"], "destination": "session"]]))
        for destination in ["userSettings", "projectSettings", "somewhereNew"] { XCTAssertNil(offer([rule(destination)]), destination) }
        XCTAssertNil(offer([rule("session", behavior: "deny")]))
        XCTAssertNil(offer([rule("session", type: "replaceRules")]))
        XCTAssertNil(offer([rule("session"), ["type": "setMode", "mode": "acceptEdits", "destination": "session"]]), "one entry it can't offer hides the row")
        XCTAssertNil(offer([["type": "addRules", "rules": [[String: Any]](), "behavior": "allow", "destination": "session"]]))
        XCTAssertNil(offer([["type": "addRules", "rules": [["ruleContent": "ls"]], "behavior": "allow", "destination": "session"]]))
        // The reply echoes the entry whole, so a field the row can't describe keeps it in the terminal.
        XCTAssertNil(offer([rule("session").merging(["directories": ["/"]]) { $1 }]))
        XCTAssertNil(offer([["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": 7]], "behavior": "allow", "destination": "session"]]))
        XCTAssertNil(offer([["type": "addRules", "rules": [["toolName": "Bash", "scope": "everywhere"]], "behavior": "allow", "destination": "session"]]))

        // And without an offer the reply is a plain allow, whatever was suggested.
        let request = Fixture.request("Bash", ["command": "ls"], suggestions: [rule("userSettings")])
        XCTAssertNil(Fixture.decision(request.hookReply(for: .allowAlways))?["updatedPermissions"])
    }

    func testCardShowsEachToolsInputInReadingOrder() {
        XCTAssertEqual(Fixture.request("Bash", ["command": "ls", "description": "List"]).parts,
                       [.init(label: "Command", text: "ls"), .init(label: "Claude says", text: "List", kind: .prose)])
        XCTAssertEqual(Fixture.request("Bash", ["cmd": "ls"]).parts.map(\.label), ["Input, as Claude sent it"], "an unknown shape is shown whole")
        let edit = Fixture.request("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y", "replace_all": true])
        XCTAssertEqual(edit.parts, [.init(label: "Replace every occurrence of", text: "x", kind: .removed), .init(label: "With", text: "y")])
        XCTAssertEqual(edit.file, "/code/app/notes.txt")
        XCTAssertEqual(Fixture.request("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y"]).parts.first?.label, "Replace")
        XCTAssertEqual(Fixture.request("Write", ["file_path": "/code/app/notes.txt", "content": "hi"]).parts, [.init(label: "New contents", text: "hi")])
        let read = Fixture.request("Read", ["file_path": "/etc/hosts"])
        XCTAssertTrue(read.parts.isEmpty)
        XCTAssertEqual(read.file, "/etc/hosts")
        XCTAssertEqual(Fixture.request("WebFetch", ["url": "https://example.com", "prompt": "Summarise"]).parts.map(\.label),
                       ["URL", "What Claude asks of the page"])
        XCTAssertEqual(Fixture.request("mcp__tracker__create_issue", ["title": "x", "repo": "a/b"]).parts,
                       [.init(label: "Input, as Claude sent it", text: "{\n  \"repo\" : \"a/b\",\n  \"title\" : \"x\"\n}")])
        XCTAssertEqual(Fixture.request("NotebookEdit", ["notebook_path": "/code/app/a.ipynb"]).file, "/code/app/a.ipynb")
    }

    /// Allow approves the whole input, so the card has to draw the whole input.
    func testEveryKeyOfTheInputIsDrawnSomewhereOnTheCard() throws {
        let inputs: [(String, [String: Any])] = [
            ("Bash", ["command": "touch build/ready", "description": "Mark the build ready", "dangerouslyDisableSandbox": true,
                      "run_in_background": true, "timeout": 600_000]),
            ("Bash", ["command": "touch build/ready", "description": ["not", "text"]]),
            ("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y", "replace_all": false, "expected_count": 3]),
            ("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y", "replace_all": "everywhere"]),
            ("Write", ["file_path": "/code/app/notes.txt", "content": "hi", "mode": "0777"]),
            ("Write", ["file_path": "/code/app/notes.txt", "notebook_path": "/code/app/other.ipynb", "content": "hi"]),
            ("Read", ["file_path": "/etc/hosts", "offset": 40, "limit": 10]),
            ("Read", ["notebook_path": "/code/app/a.ipynb", "pages": "1-3"]),
            ("WebFetch", ["url": "https://example.com", "prompt": "Summarise", "follow_redirects": true]),
            ("mcp__tracker__create_issue", ["title": "x", "repo": "a/b"]),
        ]
        for (tool, input) in inputs {
            let request = Fixture.request(tool, input)
            let drawn = request.parts.map(\.text).joined(separator: "\n")
            for (key, value) in input {
                let isInWords = request.parts.contains { $0.text == value as? String } || (key == "file_path" && request.file == value as? String)
                    || (key == "replace_all" && value is Bool)
                XCTAssertTrue(isInWords || drawn.contains("\"\(key)\" : "), "\(tool): \(key) is not on the card")
            }
        }

        let unsandboxed = Fixture.request("Bash", inputs[0].1)
        XCTAssertEqual(unsandboxed.parts.map(\.label), ["Command", "Claude says", "Also sent"])
        XCTAssertEqual(unsandboxed.parts.last?.text, "{\n  \"dangerouslyDisableSandbox\" : true,\n  \"run_in_background\" : true,\n  \"timeout\" : 600000\n}")
        XCTAssertTrue(unsandboxed.asksToLeaveSandbox)
        XCTAssertFalse(Fixture.request("Bash", ["command": "ls", "dangerouslyDisableSandbox": false]).asksToLeaveSandbox)
        XCTAssertFalse(Fixture.request("Bash", ["command": "ls"]).asksToLeaveSandbox)
        XCTAssertFalse(Fixture.request("Write", ["file_path": "/code/app/a.txt", "content": "", "dangerouslyDisableSandbox": true]).asksToLeaveSandbox)
        // Nothing extra sent, nothing extra drawn.
        XCTAssertEqual(Fixture.request("Read", ["file_path": "/etc/hosts", "offset": 40]).parts, [.init(label: "Also sent", text: "{\n  \"offset\" : 40\n}")])
        XCTAssertEqual(Fixture.request("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y", "replace_all": false]).parts.map(\.label),
                       ["Replace", "With"])
        // The allow itself still carries nothing: what runs is the input as Claude sent it.
        XCTAssertEqual(String(decoding: try XCTUnwrap(unsandboxed.hookReply(for: .allow)), as: UTF8.self), allow)
    }

    func testTitlesAndStatusLinesNameTheCall() throws {
        XCTAssertEqual(Fixture.request("Bash", [:]).title, "Run command")
        XCTAssertEqual(Fixture.request("MultiEdit", [:]).title, "Edit file")
        XCTAssertEqual(Fixture.request("mcp__tracker__create_issue", [:]).title, "MCP · tracker · create_issue")
        XCTAssertEqual(Fixture.request("Edit", ["file_path": "/code/app/notes.txt", "old_string": "x", "new_string": "y"]).summary, "Edit file · notes.txt")
        // One line of a command, which never passes for the whole of it.
        XCTAssertEqual(Fixture.request("Bash", ["command": "make test\nmake lint"]).summary, "Run command · make test (+1 more line)")
        XCTAssertEqual(Fixture.request("Bash", ["command": "# harmless\n\nrm -rf build\nls"]).summary, "Run command · # harmless (+2 more lines)")
        XCTAssertEqual(Fixture.request("Bash", ["command": String(repeating: "a", count: 300)]).summary, "Run command · " + String(repeating: "a", count: 120) + "…")
        XCTAssertEqual(Fixture.request("Bash", ["command": String(repeating: "a", count: 120)]).summary.count, "Run command · ".count + 120)
        XCTAssertEqual(Fixture.request("Glob", [:]).summary, "Glob")

        let main = try XCTUnwrap(PermissionRequest.parse(Fixture.touch))
        XCTAssertEqual(main.statusReason(waiting: 0), "Run command · touch build/ready")
        XCTAssertEqual(main.statusReason(waiting: 2), "Run command · touch build/ready · 2 more waiting")
        XCTAssertEqual(main.terminalReason, "Run command · touch build/ready · answer in the terminal")
        XCTAssertEqual(try XCTUnwrap(PermissionRequest.parse(Fixture.subagentTouch)).summary, "general-purpose subagent · Run command · touch build/ready")
        XCTAssertEqual(try XCTUnwrap(PermissionRequest.parse(Fixture.touch.merging(["agent_id": "a2"]) { $1 })).summary, "Subagent · Run command · touch build/ready")
    }

    func testCharactersThatHideOrReorderACommandAreSpelledOut() {
        XCTAssertEqual(PermissionText.visible("a\u{202E}b\rc\u{1B}[0m"), "a⟨U+202E⟩b␍c␛[0m")
        XCTAssertEqual(PermissionText.visible("ls\t-la\nrm x"), "ls\t-la\nrm x", "tabs and line breaks are part of a command")
        XCTAssertEqual(PermissionText.visible("a\u{0}b\u{8}c\u{7F}"), "a⟨U+0000⟩b⟨U+0008⟩c⟨U+007F⟩")
        XCTAssertEqual(PermissionText.visible("x\u{200B}\u{200D}\u{FEFF}\u{2066}\u{2069}\u{061C}\u{AD}y"),
                       "x⟨U+200B⟩⟨U+200D⟩⟨U+FEFF⟩⟨U+2066⟩⟨U+2069⟩⟨U+061C⟩⟨U+00AD⟩y")
        XCTAssertEqual(PermissionText.visible("t\u{E0041}\u{2028}"), "t⟨U+E0041⟩⟨U+2028⟩")
        XCTAssertEqual(PermissionText.visible("naïve café 日本語 🙂"), "naïve café 日本語 🙂")
        // Decided by what a character is, not by a list of the ones thought of so far.
        XCTAssertEqual(PermissionText.visible("sh scripts/build.sh\u{3164}"), "sh scripts/build.sh⟨U+3164⟩", "a Hangul filler is part of the file name")
        for value: UInt32 in [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x3164, 0xFE00, 0xFE0F, 0xFFA0, 0xFFF0, 0xFFF8, 0xFFF9,
                              0x1D173, 0x1D17A, 0xE0080, 0xE0100, 0xE01EF, 0xE0FFF, 0xE000, 0x10FFFF] {
            let hidden = String(Character(try! XCTUnwrap(Unicode.Scalar(value))))
            XCTAssertEqual(PermissionText.visible("g\(hidden)h"), String(format: "g⟨U+%04X⟩h", value))
        }
        // Blank but wide: nothing is drawn, and the shell keeps it in the word.
        for value: UInt32 in [0x00A0, 0x1680, 0x2000, 0x2003, 0x200A, 0x202F, 0x205F, 0x2800, 0x3000, 0xFFFC] {
            let blank = String(Character(try! XCTUnwrap(Unicode.Scalar(value))))
            XCTAssertEqual(PermissionText.visible("rm build\(blank)"), String(format: "rm build⟨U+%04X⟩", value))
        }
        let ordinary = "cafe\u{301} 한글 עברית ไทย हिन्दी  two  spaces\t~!@#$%^&*()_+{}|:\"<>?`-=[]\\;',./ end"
        XCTAssertEqual(PermissionText.visible(ordinary), ordinary, "ordinary spaces, punctuation, combining marks and other scripts are text")
        // The status line and the remembered rule go through the same filter.
        XCTAssertEqual(Fixture.request("Bash", ["command": "echo \u{202E}dlrow"]).summary, "Run command · echo ⟨U+202E⟩dlrow")
        let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "ls\u{200B}"]], "behavior": "allow", "destination": "session"]
        XCTAssertEqual(Fixture.request("Bash", ["command": "ls"], suggestions: [rule]).alwaysAllow?.rules, ["Bash(ls⟨U+200B⟩)"])
        XCTAssertEqual(Fixture.request("mcp__x\u{202E}__y", [:]).title, "MCP · x⟨U+202E⟩ · y")
    }

    func testClaudesOwnWordsKeepTheSpacesAndJoinersOrdinaryWritingUses() {
        let writing = ["Vérifier la cible\u{202F}?", "prix\u{00A0}: 10\u{00A0}€", "東京\u{3000}ビルド", "می\u{200C}خواهم",
                       "\u{26A0}\u{FE0F} careful", "👨\u{200D}👩\u{200D}👧", "1\u{FE0F}\u{20E3}"]
        for text in writing {
            XCTAssertEqual(PermissionText.visible(text, prose: true), text)
            XCTAssertNotEqual(PermissionText.visible(text), text, "a command, path or file keeps them spelled out")
        }
        // What hides or reorders words is spelled out in prose too.
        XCTAssertEqual(PermissionText.visible("ok\u{202E}\u{200B}\u{E0041}\u{FE0E}\u{2007}", prose: true), "ok⟨U+202E⟩⟨U+200B⟩⟨U+E0041⟩⟨U+FE0E⟩⟨U+2007⟩")
        // Only the parts that are Claude's own words are prose.
        let bash = Fixture.request("Bash", ["command": "echo\u{00A0}x", "description": "Vérifier\u{202F}?"])
        XCTAssertEqual(bash.parts.map(\.kind), [.code, .prose])
        let fetch = Fixture.request("WebFetch", ["url": "https://example.com", "prompt": "東京\u{3000}ビルド"])
        XCTAssertEqual(fetch.parts.map(\.kind), [.code, .prose])
        XCTAssertEqual(Fixture.request("Write", ["file_path": "/tmp/a", "content": "x"]).parts.map(\.kind), [.code])
    }

    func testVeryLongTextKeepsItsEndAndSaysWhatIsMissing() {
        XCTAssertEqual(PermissionText.bounded("short").text, "short")
        XCTAssertEqual(PermissionText.bounded("short").omitted, 0)
        let long = String(repeating: "x", count: 99_990) + "; rm -rf /"
        let shown = PermissionText.bounded(long)
        XCTAssertEqual(shown.omitted, 40_000)
        XCTAssertTrue(shown.text.hasSuffix("; rm -rf /"), "what a command ends with matters most")
        XCTAssertTrue(shown.text.contains("⋯ 40000 characters not shown ⋯"))
        XCTAssertTrue(shown.text.hasPrefix("xxxx"))
    }

    func testOneFinishedCallEndsOneRequestAndATurnBoundaryEndsTheMainAgents() throws {
        var first = try XCTUnwrap(PermissionRequest.parse(Fixture.touch))
        first.toolUseID = "t1"
        let twin = try XCTUnwrap(PermissionRequest.parse(Fixture.touch))
        let subagent = try XCTUnwrap(PermissionRequest.parse(Fixture.subagentTouch))
        let pending = [first, twin, subagent]
        let finished: [String: Any] = ["tool_name": "Bash", "tool_input": Fixture.touch["tool_input"]!]

        XCTAssertEqual(PermissionRequest.ended(by: "PostToolUse", finished.merging(["tool_use_id": "t1"]) { $1 }, among: pending), [first.id])
        XCTAssertEqual(PermissionRequest.ended(by: "PostToolUseFailure", finished.merging(["tool_use_id": "t2"]) { $1 }, among: pending), [twin.id],
                       "a known id never matches another call; the unclaimed twin matches by input")
        XCTAssertEqual(PermissionRequest.ended(by: "PostToolUse", finished.merging(["tool_use_id": "t3", "agent_id": "a1"]) { $1 }, among: pending), [subagent.id])
        XCTAssertTrue(PermissionRequest.ended(by: "PostToolUse", ["tool_name": "Bash", "tool_input": ["command": "ls"], "tool_use_id": "t4"], among: pending).isEmpty)

        XCTAssertEqual(PermissionRequest.ended(by: "Stop", [:], among: pending), [first.id, twin.id])
        XCTAssertEqual(PermissionRequest.ended(by: "UserPromptSubmit", [:], among: pending), [first.id, twin.id])
        XCTAssertEqual(PermissionRequest.ended(by: "SubagentStop", ["agent_id": "a1"], among: pending), [subagent.id])
        XCTAssertTrue(PermissionRequest.ended(by: "SubagentStop", ["agent_id": "other"], among: pending).isEmpty)
        for event in ["PreToolUse", "Notification", "SubagentStart", "mcp"] {
            XCTAssertTrue(PermissionRequest.ended(by: event, finished, among: pending).isEmpty, event)
        }
    }

    func testFingerprintIgnoresKeyOrderAndTellsAgentsApart() {
        let one = PermissionRequest.fingerprint(of: ["tool_name": "Bash", "tool_input": ["command": "ls", "description": "List"]])
        XCTAssertEqual(one, PermissionRequest.fingerprint(of: ["tool_input": ["description": "List", "command": "ls"], "tool_name": "Bash"]))
        XCTAssertNotEqual(one, PermissionRequest.fingerprint(of: ["tool_name": "Bash", "tool_input": ["command": "ls -a", "description": "List"]]))
        XCTAssertNotEqual(one, PermissionRequest.fingerprint(of: ["tool_name": "Bash", "tool_input": ["command": "ls", "description": "List"], "agent_id": "a1"]))
        XCTAssertEqual(PermissionRequest.parse(["tool_name": "Bash", "tool_input": ["command": "ls", "description": "List"]])?.fingerprint, one)
    }

    func testPermissionRequiredIsItsOwnStatusCountedWithNeedsYou() throws {
        let status = SessionStatus.permissionRequired("Run command · touch build/ready")
        XCTAssertEqual(status.label, "Permission required")
        XCTAssertTrue(status.needsAttention)
        XCTAssertFalse(status.isFinished)
        XCTAssertEqual(status.sortRank, SessionStatus.needsYou("x").sortRank)
        XCTAssertEqual(status.color, SessionStatus.needsYou("x").color)
        let attention = try XCTUnwrap(status.attention)
        XCTAssertEqual(attention.title, "Permission required")
        XCTAssertEqual(attention.reason, "Run command · touch build/ready")
        XCTAssertEqual(attention.symbol, "lock.shield.fill")
        XCTAssertEqual(SessionStatus.needsYou("Pick one").attention?.title, "Needs you")
        XCTAssertEqual(SessionStatus.needsYou("Pick one").attention?.symbol, "hand.raised.fill")
        for quiet in [SessionStatus.starting, .working, .waiting, .yourTurn, .done(nil), .ended("x"), .exited(0), .paused, .interrupted] {
            XCTAssertNil(quiet.attention)
            XCTAssertFalse(quiet.needsAttention)
        }
    }

    @MainActor
    func testStoredPermissionStatusSurvivesTheDatabaseAndComesBackInterrupted() throws {
        let (name, detail) = SessionDatabase.encode(.permissionRequired("Run command · touch build/ready · answer in the terminal"))
        XCTAssertEqual(name, "permission_required")
        XCTAssertEqual(SessionDatabase.decode(name, detail: detail), .permissionRequired("Run command · touch build/ready · answer in the terminal"))
        XCTAssertEqual(SessionDatabase.decode("permission_required", detail: nil), .permissionRequired(""))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try SessionDatabase(url: folder.appendingPathComponent("test.sqlite"))
        let session = AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: folder)
        session.status = .permissionRequired("Run command · touch build/ready")
        try database.save(session)
        // Nothing is running after a relaunch, and the held hook is gone with the old process.
        XCTAssertEqual(try database.load().first?.status, .interrupted)
    }
}
