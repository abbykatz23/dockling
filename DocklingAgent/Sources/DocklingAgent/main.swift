import AppKit

let hookPort: UInt16 = 8765

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockIcon = DockIconController()
    private var server: HookServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        dockIcon.apply(.idle)

        let server = HookServer(port: hookPort) { [weak self] event in
            self?.handle(event)
        }
        server.start()
        self.server = server
    }

    private func handle(_ event: HookEvent) {
        switch event.name {
        case "SessionStart":
            dockIcon.apply(.idle)
        case "PreToolUse":
            let bucket = event.toolName.map(DockState.bucket(forToolName:)) ?? .other
            dockIcon.apply(bucket)
        case "PostToolUseFailure":
            dockIcon.apply(.error)
        case "Notification":
            dockIcon.apply(.awaitingInput)
        case "Stop", "StopFailure":
            dockIcon.apply(.idle)
        case "SessionEnd":
            dockIcon.apply(.idle)
        default:
            break
        }
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
