import Foundation
import Network

/// Minimal local HTTP server that receives Claude Code's `type: "http"` hook
/// POSTs. Used both by the dispatcher (well-known port, all sessions) and by
/// each per-session child (its own ephemeral port, forwarded events only).
/// No auth token, no persistence — see DOCKLING_SPEC.md Security section for
/// what a real build needs before this listens on anything but localhost.
final class HookServer {
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private let onEvent: ([String: Any], HookEvent) -> Void

    init(port: UInt16, onEvent: @escaping ([String: Any], HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
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
                    if let json = Self.parseCompleteRequest(buffer) {
                        self.respondOK(connection)
                        if let parsed = HookEvent(json: json) {
                            self.onEvent(json, parsed)
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

    /// Returns the parsed JSON body once the full HTTP request (headers + body per
    /// Content-Length) has arrived, else nil to keep reading.
    private static func parseCompleteRequest(_ buffer: Data) -> [String: Any]? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[..<headerEnd.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        var contentLength = 0
        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let value = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let body = buffer[bodyStart...]
        guard body.count >= contentLength else { return nil }
        let exactBody = body.prefix(contentLength)
        guard let json = try? JSONSerialization.jsonObject(with: Data(exactBody)) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func respondOK(_ connection: NWConnection) {
        let body = "{}"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct HookEvent {
    let sessionID: String?
    let name: String
    let toolName: String?
    let tmuxPane: String? // only present on the SessionStart command hook — see report_session_start.sh

    init?(json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String else { return nil }
        self.name = name
        self.sessionID = json["session_id"] as? String
        self.toolName = json["tool_name"] as? String
        let pane = json["tmux_pane"] as? String
        self.tmuxPane = (pane?.isEmpty ?? true) ? nil : pane
    }
}
