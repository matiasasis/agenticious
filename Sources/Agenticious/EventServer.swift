import Foundation
import Network

/// One signal from a running agent: a Claude Code hook, a Codex `notify`, or a call to the agenticious MCP tools.
struct AgentEvent: Sendable {
    let sessionID: UUID
    let name: String
    let body: Data
}

/// Anything else asked of the server by another tool on this Mac, such as the Stream Deck plugin's `GET /presets`.
struct LocalRequest: Sendable, Equatable {
    let method: String
    let path: [String]
}

/// Tiny loopback HTTP server. Agents report in with `POST /hook/<session-id>/<event-name>` and a JSON body.
/// The handler may answer with a JSON body, which is how a Claude hook gets its reply (see `stopHookReply`).
final class EventServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentEvent, @escaping @Sendable (Data?) -> Void) -> Void
    typealias RequestHandler = @Sendable (LocalRequest, @escaping @Sendable (Data?) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agenticious.events")
    private let onEvent: Handler
    private let onRequest: RequestHandler

    init(port: UInt16, onRequest: @escaping RequestHandler = { _, reply in reply(nil) }, onEvent: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.onEvent = onEvent
        self.onRequest = onRequest
    }

    func start() {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(parsing: buffer) {
                self.route(request) { body in self.reply(on: connection, body: body) }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, reply: @escaping @Sendable (Data?) -> Void) {
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "hook", let id = UUID(uuidString: parts[1]) else {
            return request.local.map { onRequest($0, reply) } ?? reply(nil)
        }

        onEvent(AgentEvent(sessionID: id, name: parts[2], body: request.body), reply)
    }

    private func reply(on connection: NWConnection, body: Data?) {
        let head = body.map { "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \($0.count)\r\n" }
            ?? "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n"
        let response = Data((head + "Connection: close\r\n\r\n").utf8) + (body ?? Data())
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
    /// Set by browsers on requests a web page makes to another site.
    let origin: String?
    /// The name the client connected to: this Mac's own for a local tool, its own site's for a page whose name was
    /// re-pointed here (DNS rebinding), which the browser then treats as same-site and sends no Origin for.
    let host: String?

    /// The request as another local tool's, or nil when a web page sent it: any page can make the browser call
    /// a loopback port, and none has business opening windows here.
    var local: LocalRequest? {
        guard origin == nil, host.map(Self.isLoopback) ?? true else { return nil }
        let path = path.prefix { $0 != "?" }.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        return LocalRequest(method: method, path: path)
    }

    private static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return ["127.0.0.1", "localhost", "[::1]"].contains { host == $0 || host.hasPrefix($0 + ":") }
    }

    /// Returns nil until the whole request (headers + Content-Length bytes of body) has arrived.
    init?(parsing data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        let contentLength = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }

        func header(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        method = String(requestLine[0])
        origin = header("origin")
        host = header("host")
        path = String(requestLine[1])
        self.body = Data(body.prefix(contentLength))
    }
}
