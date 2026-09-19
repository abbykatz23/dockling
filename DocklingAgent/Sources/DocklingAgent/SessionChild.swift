import AppKit

/// Runs as a dedicated process for exactly one Claude Code session: owns a
/// single Dock icon (via NSApp.applicationIconImage) and listens on its own
/// port for events the dispatcher forwards to it. Exits when its session ends.
final class SessionChildDelegate: NSObject, NSApplicationDelegate {
    private let sessionID: String
    private let port: UInt16
    private let dockIcon = DockIconController()
    private var server: HookServer?
    private var tmuxPane: String? // learned from SessionStart; needed to send a reply via `tmux send-keys`
    private var pendingQuestion: String = "Claude is waiting for your input."
    private var lastToolDescription: String? // remembered from the most recent PreToolUse, since Notification's own message is generic
    private lazy var replyPanel = ReplyPanelController { [weak self] text in
        self?.submitReply(text)
    }

    init(sessionID: String, port: UInt16) {
        self.sessionID = sessionID
        self.port = port
    }

    /// Clicking the Dock icon while there are no visible windows routes here.
    /// Only pops the reply panel while actually awaiting input — otherwise a
    /// click just activates the (windowless) app, same as any other Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard dockIcon.currentState == .awaitingInput else { return true }
        replyPanel.show(question: pendingQuestion)
        return true
    }

    private func submitReply(_ text: String) {
        guard let pane = tmuxPane else {
            let alert = NSAlert()
            alert.messageText = "Can't deliver reply"
            alert.informativeText = "This session isn't running inside tmux, so Dockling has no terminal pane to send the reply to."
            alert.runModal()
            return
        }
        fputs("[dockling] session \(sessionID) sending reply to pane \(pane)\n", stderr)
        TmuxReply.send(text: text, toPane: pane)
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
            lastToolDescription = event.toolDescription
        case "PostToolUseFailure":
            dockIcon.apply(.error)
        case "TaskCompleted":
            dockIcon.apply(.eureka)
        case "Notification":
            if event.notificationType == "permission_prompt", let description = lastToolDescription {
                pendingQuestion = description
            } else {
                pendingQuestion = event.message ?? "Claude is waiting for your input."
            }
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
