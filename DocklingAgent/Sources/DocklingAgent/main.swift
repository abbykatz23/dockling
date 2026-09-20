import Foundation

let hookPort: UInt16 = 8765
let sharedSecret = DocklingSecret.load()

let arguments = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
    return arguments[idx + 1]
}

if arguments.contains("--install") {
    guard let repoRoot = argValue("--repo-root") else {
        fputs("error: --install requires --repo-root <path>\n", stderr)
        exit(1)
    }
    Installer.run(repoRoot: repoRoot)
} else if let sessionID = argValue("--session"), let portString = argValue("--port"), let port = UInt16(portString) {
    let color = argValue("--color") ?? "yellow"
    let name = argValue("--name") ?? "DocklingAgent"
    let agentID = argValue("--agent")
    let parentPort = argValue("--parent-port").flatMap(UInt16.init) ?? hookPort
    runSessionChild(sessionID: sessionID, port: port, color: color, name: name, agentID: agentID, parentPort: parentPort)
} else {
    runDispatcher(port: hookPort)
}
