import Foundation

// Minimal MCP server (JSON-RPC over stdio) that the agent uses to report its plan and ask for the human.
// Every tool call is forwarded to the Agenticious app at POST /hook/<session>/mcp.

let environment = ProcessInfo.processInfo.environment
let sessionID = environment["AGENTICIOUS_SESSION"] ?? ""
let port = environment["AGENTICIOUS_PORT"] ?? "47821"

let statusValues = ["pending", "in_progress", "done", "blocked"]

let tools: [[String: Any]] = [
    [
        "name": "set_plan",
        "description": "Show the human your plan as 3-8 chunks. Call it before starting work, and again whenever the plan changes.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "chunks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["title": ["type": "string", "description": "6 words or fewer"]],
                        "required": ["title"],
                    ],
                ],
            ],
            "required": ["chunks"],
        ],
    ],
    [
        "name": "update_chunk",
        "description": "Update one chunk's status. `index` is 1-based, in the order you passed to set_plan.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "index": ["type": "integer"],
                "status": ["type": "string", "enum": statusValues],
                "note": ["type": "string", "description": "Optional short note, e.g. why it's blocked"],
            ],
            "required": ["index", "status"],
        ],
    ],
    [
        "name": "need_human",
        "description": "Flag that you're blocked on the human. Pass a one-line question, then ask it in the terminal.",
        "inputSchema": [
            "type": "object",
            "properties": ["reason": ["type": "string"]],
            "required": ["reason"],
        ],
    ],
    [
        "name": "finish",
        "description": "Mark the whole task complete, with a two-sentence summary of what changed.",
        "inputSchema": [
            "type": "object",
            "properties": ["summary": ["type": "string"]],
            "required": ["summary"],
        ],
    ],
]

func send(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func reply(_ id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func fail(_ id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

/// Blocks until Agenticious acknowledges, so the dashboard is updated before the agent moves on.
func forward(tool: String, arguments: [String: Any]) -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(port)/hook/\(sessionID)/mcp"),
          let body = try? JSONSerialization.data(withJSONObject: ["tool": tool, "args": arguments]) else { return false }

    var request = URLRequest(url: url, timeoutInterval: 2)
    request.httpMethod = "POST"
    request.httpBody = body

    let done = DispatchSemaphore(value: 0)
    var delivered = false
    URLSession.shared.dataTask(with: request) { _, response, _ in
        delivered = (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        done.signal()
    }.resume()
    done.wait()
    return delivered
}

func callTool(_ id: Any, _ params: [String: Any]) {
    guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
        return fail(id, code: -32602, message: "Unknown tool")
    }

    let delivered = forward(tool: name, arguments: params["arguments"] as? [String: Any] ?? [:])
    let text = delivered ? "Shown on the Agenticious dashboard." : "Agenticious isn't reachable. Carry on normally."
    reply(id, result: ["content": [["type": "text", "text": text]]])
}

while let line = readLine() {
    guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
          let id = message["id"] else { continue } // notifications need no response

    let params = message["params"] as? [String: Any] ?? [:]

    switch message["method"] as? String {
    case "initialize":
        reply(id, result: [
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": "agenticious", "version": "0.1.0"],
        ])
    case "tools/list":
        reply(id, result: ["tools": tools])
    case "tools/call":
        callTool(id, params)
    case "ping":
        reply(id, result: [:])
    default:
        fail(id, code: -32601, message: "Method not found")
    }
}
