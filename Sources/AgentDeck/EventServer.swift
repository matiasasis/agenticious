import Foundation
import Network

/// One signal from a running agent: a Claude Code hook, a Codex `notify`, or a call to the agentdeck MCP tools.
struct AgentEvent: Sendable {
    let sessionID: UUID
    let name: String
    let body: Data
}

/// Tiny loopback HTTP server. Agents report in with `POST /hook/<session-id>/<event-name>` and a JSON body.
/// The handler may answer with a JSON body, which is how a Claude hook gets its reply (see `stopHookReply`).
final class EventServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentEvent, @escaping @Sendable (Data?) -> Void) -> Void

    private let listener: NWListener
    private let queue = DispatchQueue(label: "agentdeck.events")
    private let onEvent: Handler

    init(port: UInt16, onEvent: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.onEvent = onEvent
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
        guard parts.count == 3, parts[0] == "hook", let id = UUID(uuidString: parts[1]) else { return reply(nil) }

        onEvent(AgentEvent(sessionID: id, name: parts[2], body: request.body), reply)
    }

    private func reply(on connection: NWConnection, body: Data?) {
        let head = body.map { "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \($0.count)\r\n" }
            ?? "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n"
        let response = Data((head + "Connection: close\r\n\r\n").utf8) + (body ?? Data())
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

private struct HTTPRequest {
    let path: String
    let body: Data

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

        path = String(requestLine[1])
        self.body = Data(body.prefix(contentLength))
    }
}
