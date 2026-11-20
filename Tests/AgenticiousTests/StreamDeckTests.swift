import AppKit
import XCTest
@testable import Agenticious

@MainActor
final class StreamDeckTests: XCTestCase {
    private let presets = [
        TaskTemplate(id: "custom", name: "Custom task"),
        TaskTemplate(id: "DE16986F 6E91", name: "Ask for Review", symbol: "hand.thumbsup"),
        TaskTemplate(id: "odd", name: "Technical discovery", symbol: "not.a.real.symbol"),
    ]

    private func answer(_ method: String, _ path: [String], summon: (TaskTemplate) -> Bool = { _ in true }) throws -> [String: Any]? {
        try StreamDeck.answer(LocalRequest(method: method, path: path), presets: presets, summon: summon)
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    func testDeckGetsEveryPresetInArrangedOrderWithAKeyImage() throws {
        let keys = try XCTUnwrap(answer("GET", ["presets"])?["presets"] as? [[String: String]])
        XCTAssertEqual(keys.map { $0["id"] }, ["custom", "DE16986F 6E91", "odd"])
        XCTAssertEqual(keys.map { $0["name"] }, ["Custom task", "Ask for Review", "Technical discovery"])
        for key in keys {
            let image = try XCTUnwrap(key["image"])
            XCTAssertTrue(image.hasPrefix("data:image/png;base64,"))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(Data(base64Encoded: String(image.dropFirst("data:image/png;base64,".count))))))
            XCTAssertEqual([bitmap.pixelsWide, bitmap.pixelsHigh], [StreamDeck.keySize, StreamDeck.keySize])
        }
        // Different presets get different keys, an unknown symbol included.
        XCTAssertEqual(Set(keys.compactMap { $0["image"] }).count, 3)
    }

    func testPressingAKeySummonsItsPresetAndAnUnknownOneSaysSo() throws {
        var summoned: [String] = []
        XCTAssertEqual(try answer("POST", ["summon", "DE16986F 6E91"]) { summoned.append($0.id); return true }?["ok"] as? Bool, true)
        XCTAssertEqual(try answer("POST", ["summon", "deleted"]) { summoned.append($0.id); return true }?["ok"] as? Bool, false)
        XCTAssertEqual(summoned, ["DE16986F 6E91"])
        // The window couldn't open (a folder picker is up): the deck must not treat that as done.
        XCTAssertEqual(try answer("POST", ["summon", "custom"]) { _ in false }?["ok"] as? Bool, false)
    }

    func testOnlyThePluginsOwnRequestsAreAnswered() throws {
        var summoned = 0
        XCTAssertNil(try answer("GET", ["summon", "custom"]) { _ in summoned += 1; return true })
        XCTAssertNil(try answer("POST", ["presets"]))
        XCTAssertNil(try answer("GET", ["presets", "custom"]))
        XCTAssertNil(try answer("GET", []))
        XCTAssertEqual(summoned, 0)
    }

    func testRequestsFromWebPagesAreNotLocalOnes() throws {
        func request(_ text: String) -> HTTPRequest? { HTTPRequest(parsing: Data(text.utf8)) }
        XCTAssertEqual(request("POST /summon/DE16986F%206E91?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")?.local,
                       LocalRequest(method: "POST", path: ["summon", "DE16986F 6E91"]))
        XCTAssertEqual(request("GET /presets HTTP/1.1\r\n\r\n")?.local, LocalRequest(method: "GET", path: ["presets"]))
        // A page calling the loopback port: the browser says where the request came from.
        XCTAssertNil(request("POST /summon/custom HTTP/1.1\r\nOrigin: https://example.com\r\nContent-Length: 0\r\n\r\n")?.local)
        XCTAssertNil(request("GET /presets HTTP/1.1\r\norigin: null\r\n\r\n")?.local)
        // A page whose own name was re-pointed at this Mac: same-site to the browser, so it sends no Origin.
        XCTAssertNil(request("GET /presets HTTP/1.1\r\nHost: attacker.example:47821\r\n\r\n")?.local)
        XCTAssertNil(request("GET /presets HTTP/1.1\r\nHost: localhost.attacker.example\r\n\r\n")?.local)
        XCTAssertEqual(request("GET /presets HTTP/1.1\r\nhost: 127.0.0.1:47821\r\n\r\n")?.local, LocalRequest(method: "GET", path: ["presets"]))
        XCTAssertEqual(request("GET /presets HTTP/1.1\r\nHost: LOCALHOST\r\n\r\n")?.local, LocalRequest(method: "GET", path: ["presets"]))
        // Agents' hooks are parsed as before.
        let hook = try XCTUnwrap(request("POST /hook/abc/Stop HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"))
        XCTAssertEqual(hook.path, "/hook/abc/Stop")
        XCTAssertEqual(hook.body, Data("{}".utf8))
    }
}
