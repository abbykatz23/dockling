import Foundation

let hookPort: UInt16 = 8765
let sharedSecret = DocklingSecret.load()
let dockingConfig = DocklingConfig.load()

let arguments = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
    return arguments[idx + 1]
}

if arguments.contains("--install") {
    Installer.run()
} else if let sessionID = argValue("--session"), let portString = argValue("--port"), let port = UInt16(portString) {
    let color = argValue("--color") ?? "yellow"
    let name = argValue("--name") ?? "DocklingAgent"
    let agentID = argValue("--agent")
    let parentPort = argValue("--parent-port").flatMap(UInt16.init) ?? hookPort
    runSessionChild(sessionID: sessionID, port: port, color: color, name: name, agentID: agentID, parentPort: parentPort)
} else if arguments.contains("--dispatcher") {
    // launchd's own launch of the real, headless, long-running dispatcher —
    // see LaunchdRegistration for why this needs its own flag rather than
    // just being the plain no-args case.
    runDispatcher(port: hookPort)
} else {
    // A plain double-click in Finder, with no arguments at all — show the
    // first-run install UI instead of silently becoming an invisible
    // dispatcher with nothing on screen.
    runFirstRunApp()
}
