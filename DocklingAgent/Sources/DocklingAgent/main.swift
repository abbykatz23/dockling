import Foundation

let hookPort: UInt16 = 8765
let sharedSecret = DocklingSecret.load()

let arguments = CommandLine.arguments
func argValue(_ flag: String) -> String? {
    guard let idx = arguments.firstIndex(of: flag), idx + 1 < arguments.count else { return nil }
    return arguments[idx + 1]
}

if let sessionID = argValue("--session"), let portString = argValue("--port"), let port = UInt16(portString) {
    let color = argValue("--color") ?? "yellow"
    let name = argValue("--name") ?? "DocklingAgent"
    runSessionChild(sessionID: sessionID, port: port, color: color, name: name)
} else {
    runDispatcher(port: hookPort)
}
