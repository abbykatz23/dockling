import Foundation
import Network

/// Minimal local HTTP server that receives Claude Code's `type: "http"` hook
/// POSTs. Used both by the dispatcher (well-known port, all sessions) and by
/// each per-session child (its own ephemeral port, forwarded events only).
/// Requires a `?token=` query param matching the per-install secret (see
/// Secret.swift) on every request — otherwise any other local process could
/// POST a fake event or trigger a fake reply popover (DOCKLING_SPEC.md's
/// "local channel auth" requirement).
final class HookServer {
    private let port: NWEndpoint.Port
    private let expectedToken: String
    private var listener: NWListener?
    private let onEvent: ([String: Any], HookEvent) -> Void

    init(port: UInt16, expectedToken: String, onEvent: @escaping ([String: Any], HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.expectedToken = expectedToken
        self.onEvent = onEvent
    }

    func start() {
        let params = NWParameters.tcp
        guard let listener = try? NWListener(using: params, on: port) else {
            fputs("[dockling] failed to bind port \(port)\n", stderr)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("[dockling] listener failed: \(error)\n", stderr)
            }
        }
        listener.start(queue: .main)
        fputs("[dockling] hook server listening on 127.0.0.1:\(port.rawValue)\n", stderr)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        var buffer = Data()
        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let request = Self.parseCompleteRequest(buffer) {
                        guard request.token == self.expectedToken else {
                            fputs("[dockling] rejecting request on port \(self.port.rawValue): missing/invalid token\n", stderr)
                            self.respond(connection, status: "401 Unauthorized")
                            return
                        }
                        self.respond(connection, status: "200 OK")
                        if let parsed = HookEvent(json: request.json) {
                            self.onEvent(request.json, parsed)
                        }
                        return
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receiveMore()
            }
        }
        receiveMore()
    }

    private struct ParsedRequest {
        let token: String?
        let json: [String: Any]
    }

    /// Returns the parsed request (query-string token + JSON body) once the
    /// full HTTP request (headers + body per Content-Length) has arrived,
    /// else nil to keep reading.
    private static func parseCompleteRequest(_ buffer: Data) -> ParsedRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let headerLines = headerString.components(separatedBy: "\r\n")

        var contentLength = 0
        for line in headerLines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }

        let requestLineParts = headerLines.first?.split(separator: " ") ?? []
        let path = requestLineParts.count >= 2 ? String(requestLineParts[1]) : ""
        let token = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "token" })?.value

        let bodyStart = headerEnd.upperBound
        let body = buffer[bodyStart...]
        guard body.count >= contentLength else { return nil }
        let exactBody = body.prefix(contentLength)
        let parsedJSON = (try? JSONSerialization.jsonObject(with: Data(exactBody)) as? [String: Any]) ?? nil
        return ParsedRequest(token: token, json: parsedJSON ?? [:])
    }

    private func respond(_ connection: NWConnection, status: String) {
        let body = "{}"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HookEvent {
    let sessionID: String?
    let name: String
    let toolName: String?
    let toolInput: [String: Any]? // PreToolUse only: the tool's arguments, e.g. {"command": "..."} for Bash
    let tmuxPane: String? // only present on the SessionStart command hook — see report_session_start.sh
    let message: String? // Notification only: a generic string like "Claude needs your permission" — not the specific question
    let notificationType: String? // Notification only: "permission_prompt", "idle_prompt", etc.
    let cwd: String? // present on every event; used to name the Dock tile after the project

    /// A human-readable description of what a tool call is about to do, built
    /// from tool_name + tool_input. Notification events don't carry this
    /// themselves (their `message` is generic), so the caller remembers the
    /// most recent PreToolUse's description to show a real question instead.
    var toolDescription: String? {
        guard let toolName, let toolInput else { return toolName }
        switch toolName {
        case "Bash":
            return (toolInput["command"] as? String).map { "Run: \($0)" }
        case "Edit", "Write", "NotebookEdit", "MultiEdit":
            return (toolInput["file_path"] as? String).map { "Edit: \($0)" }
        case "Grep", "Glob":
            return (toolInput["pattern"] as? String).map { "Search: \($0)" }
        case "WebSearch":
            return (toolInput["query"] as? String).map { "Web search: \($0)" }
        case "WebFetch":
            return (toolInput["url"] as? String).map { "Fetch: \($0)" }
        case "AskUserQuestion":
            guard let question = (toolInput["questions"] as? [[String: Any]])?.first,
                  let text = question["question"] as? String else {
                return toolName
            }
            let options = (question["options"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
            guard !options.isEmpty else { return text }
            let numbered = options.enumerated().map { "\($0.offset + 1). \($0.element)" }
            return ([text] + numbered).joined(separator: "\n")
        default:
            return toolName
        }
    }

    init?(json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String else { return nil }
        self.name = name
        self.sessionID = json["session_id"] as? String
        self.toolName = json["tool_name"] as? String
        self.toolInput = json["tool_input"] as? [String: Any]
        self.message = json["message"] as? String
        self.notificationType = json["notification_type"] as? String
        self.cwd = json["cwd"] as? String
        let pane = json["tmux_pane"] as? String
        self.tmuxPane = (pane?.isEmpty ?? true) ? nil : pane
    }
}
