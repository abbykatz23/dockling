import Foundation
import Network

/// Minimal local HTTP server that receives Claude Code's `type: "http"` hook
/// POSTs. Used both by the dispatcher (well-known port, all sessions) and by
/// each per-session child (its own ephemeral port, forwarded events only).
/// Requires a `?token=` query param matching the per-install secret (see
/// Secret.swift) on every request — otherwise any other local process could
/// POST a fake event (DOCKLING_SPEC.md's "local channel auth" requirement).
final class HookServer {
    private let port: NWEndpoint.Port
    private let expectedToken: String
    private var listener: NWListener?
    private let onEvent: ([String: Any], HookEvent) -> Void
    // Only ever set for a session child's own server (see SessionChild.swift)
    // — called once bindAttemptsLeft is exhausted with the port still taken.
    // Left nil for the dispatcher's well-known port, which never contends
    // with a same-process relaunch the way a session child's does, so
    // logging and otherwise doing nothing has always been the right call
    // there.
    private let onBindFailureExhausted: (() -> Void)?

    init(port: UInt16, expectedToken: String, onBindFailureExhausted: (() -> Void)? = nil, onEvent: @escaping ([String: Any], HookEvent) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.expectedToken = expectedToken
        self.onBindFailureExhausted = onBindFailureExhausted
        self.onEvent = onEvent
    }

    /// Retries briefly on bind failure: a session child relaunching itself
    /// onto its own port (see SessionChild.swift's self-relaunch, used to
    /// keep the "primary" duck trailing its subagent babies in the Dock) has
    /// a short window where the old and new processes both want the same
    /// port, and the new one needs to wait for the old one to release it.
    ///
    /// The retry used to be wired to the wrong signal: `NWListener(using:)`'s
    /// initializer essentially never throws for a port already in use —
    /// confirmed by reproducing the exact race (two real DocklingAgent
    /// processes started on the same port a few seconds apart) — the
    /// conflict only ever surfaces afterward, asynchronously, via
    /// `stateUpdateHandler`'s `.failed` case, well after `start()` has
    /// already been called and already logged "listening" below. The old
    /// code only retried on the synchronous throw, so a relaunching session
    /// child that lost this (fully expected, happens on every relaunch)
    /// race just sat there forever with a permanently-failed listener: still
    /// running, still showing a Dock icon frozen at whatever pose the
    /// handoff restored, but never able to receive another hook event again
    /// — which matches this exact leak, reproduced and now fixed here.
    ///
    /// 100 attempts at 0.1s apart (10s total) rather than the previous 20
    /// (2s): timing the real recovery (kill the old process, measure how
    /// long a freshly-retrying listener takes to actually bind) showed
    /// ~0.4-0.7s under no load — comfortably inside even the old budget —
    /// but that was one quiet machine with nothing else contending for
    /// scheduler time. A real session under load (several babies relaunching
    /// in the same burst, each competing for CPU) has no guarantee of
    /// staying that fast, and there's no real cost to a longer budget on the
    /// success path — it only ever waits as long as binding actually takes.
    /// The failure path (see onBindFailureExhausted below) is the actual
    /// backstop either way, so a generous budget here just makes hitting it
    /// less likely, not less safe if it is hit.
    func start(bindAttemptsLeft: Int = 100) {
        let params = NWParameters.tcp
        // Binds only the loopback interface — without this, NWListener binds
        // all interfaces despite the port still just being "127.0.0.1" in
        // logs/comments, making the hook port (and its token-guessing
        // surface) reachable from anyone else on the same network, not just
        // this machine.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        guard let listener = try? NWListener(using: params) else {
            retryOrGiveUp(bindAttemptsLeft: bindAttemptsLeft)
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                fputs("[dockling] hook server listening on 127.0.0.1:\(self.port.rawValue)\n", stderr)
            case .failed(let error):
                fputs("[dockling] listener failed to bind 127.0.0.1:\(self.port.rawValue): \(error)\n", stderr)
                // A failed listener is done for good — Network.framework
                // doesn't recover it, so this cancels it and lets the retry
                // build a fresh one, same as the synchronous-throw path
                // above always did.
                listener.cancel()
                if self.listener === listener { self.listener = nil }
                self.retryOrGiveUp(bindAttemptsLeft: bindAttemptsLeft)
            default:
                break
            }
        }
        listener.start(queue: .main)
    }

    private func retryOrGiveUp(bindAttemptsLeft: Int) {
        if bindAttemptsLeft > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.start(bindAttemptsLeft: bindAttemptsLeft - 1)
            }
        } else {
            fputs("[dockling] giving up on binding port \(port.rawValue) after repeated attempts\n", stderr)
            onBindFailureExhausted?()
        }
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
                        // tmux_pane arrives as a query param, not in the JSON
                        // body (see report_session_start.sh — this avoids
                        // needing jq or any other JSON tool in that shell
                        // script), so fold it in here before handing the
                        // event off.
                        var json = request.json
                        if let pane = request.tmuxPane { json["tmux_pane"] = pane }
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

    private struct ParsedRequest {
        let token: String?
        let tmuxPane: String?
        let json: [String: Any]
    }

    /// Returns the parsed request (query-string token/tmux_pane + JSON body)
    /// once the full HTTP request (headers + body per Content-Length) has
    /// arrived, else nil to keep reading.
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
        let queryItems = URLComponents(string: path)?.queryItems ?? []
        let token = queryItems.first(where: { $0.name == "token" })?.value
        let tmuxPane = queryItems.first(where: { $0.name == "tmux_pane" })?.value

        let bodyStart = headerEnd.upperBound
        let body = buffer[bodyStart...]
        guard body.count >= contentLength else { return nil }
        let exactBody = body.prefix(contentLength)
        let parsedJSON = (try? JSONSerialization.jsonObject(with: Data(exactBody)) as? [String: Any]) ?? nil
        return ParsedRequest(token: token, tmuxPane: tmuxPane, json: parsedJSON ?? [:])
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
    let cwd: String? // present on every event; used to name the Dock tile after the project
    let agentID: String? // present only on events from a subagent's own tool calls, not the top-level session's
    let agentType: String? // e.g. "general-purpose" — present alongside agentID

    init?(json: [String: Any]) {
        guard let name = json["hook_event_name"] as? String else { return nil }
        self.name = name
        self.sessionID = json["session_id"] as? String
        self.toolName = json["tool_name"] as? String
        self.toolInput = json["tool_input"] as? [String: Any]
        self.cwd = json["cwd"] as? String
        self.agentID = json["agent_id"] as? String
        self.agentType = json["agent_type"] as? String
        let pane = json["tmux_pane"] as? String
        self.tmuxPane = (pane?.isEmpty ?? true) ? nil : pane
    }
}
