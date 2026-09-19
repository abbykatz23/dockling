import AppKit

/// Runs as a dedicated process for exactly one Claude Code session: owns a
/// single Dock icon (via NSApp.applicationIconImage) and listens on its own
/// port for events the dispatcher forwards to it. Exits when its session ends.
final class SessionChildDelegate: NSObject, NSApplicationDelegate {
    private let sessionID: String
    private let port: UInt16
    private let dockIcon = DockIconController()
    private var server: HookServer?
    private var tmuxPane: String? // learned from SessionStart; needed later to send a reply via `tmux send-keys`

    init(sessionID: String, port: UInt16) {
        self.sessionID = sessionID
        self.port = port
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        dockIcon.apply(.idle)
        fputs("[dockling] session \(sessionID) child started on port \(port)\n", stderr)

        let server = HookServer(port: port) { [weak self] _, event in
            self?.handle(event)
        }
        server.start()
        self.server = server
    }

    private func handle(_ event: HookEvent) {
        switch event.name {
        case "SessionStart":
            dockIcon.apply(.idle)
            if let pane = event.tmuxPane {
                tmuxPane = pane
                fputs("[dockling] session \(sessionID) learned tmux pane \(pane)\n", stderr)
            }
        case "PreToolUse":
            let bucket = event.toolName.map(DockState.bucket(forToolName:)) ?? .other
            dockIcon.apply(bucket)
        case "PostToolUseFailure":
            dockIcon.apply(.error)
        case "TaskCompleted":
            dockIcon.apply(.eureka)
        case "Notification":
            dockIcon.apply(.awaitingInput)
        case "Stop", "StopFailure":
            dockIcon.apply(.idle)
        case "SessionEnd":
            fputs("[dockling] session \(sessionID) ended, exiting\n", stderr)
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

func runSessionChild(sessionID: String, port: UInt16) -> Never {
    let delegate = SessionChildDelegate(sessionID: sessionID, port: port)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}
