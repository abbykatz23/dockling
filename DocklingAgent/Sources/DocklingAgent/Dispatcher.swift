import Foundation

/// Stays bound to the single well-known port that `.claude/settings.json`
/// points every hook at (so hook config never needs to change per session),
/// and fans events out to one child process per `session_id`. Each child owns
/// its own Dock icon (see SessionChild.swift); the dispatcher itself has no
/// AppKit UI and never sets an activation policy, so it never appears in the
/// Dock — only session children do, per DOCKLING_SPEC.md's multi-session design.
final class Dispatcher {
    // Must stay in sync with the `colors` list in tools/generate_dock_icons.swift,
    // which is what actually produces Resources/<color>/*.png for each of these.
    private static let colors = ["yellow", "blue", "babyblue", "gray", "green", "lavender", "orange", "pink", "tan"]

    private final class Session {
        let process: Process
        let port: UInt16
        let color: String
        var tmuxPane: String? // learned from the SessionStart command hook, if any

        init(process: Process, port: UInt16, color: String) {
            self.process = process
            self.port = port
            self.color = color
        }
    }

    private var sessions: [String: Session] = [:]
    private var nextPort: UInt16 = 8766
    private let urlSession = URLSession(configuration: .ephemeral)
    private var server: HookServer? // must be retained — see the bug this fixed below

    func start(onPort port: UInt16) {
        let server = HookServer(port: port) { [weak self] rawJSON, event in
            self?.route(rawJSON: rawJSON, event: event)
        }
        server.start()
        self.server = server
    }

    private func route(rawJSON: [String: Any], event: HookEvent) {
        guard let sessionID = event.sessionID else {
            fputs("[dockling] dropping event with no session_id: \(event.name)\n", stderr)
            return
        }

        if event.name == "SessionEnd" {
            guard let session = sessions[sessionID] else { return }
            forward(rawJSON: rawJSON, to: session.port, attemptsLeft: 1)
            sessions.removeValue(forKey: sessionID)
            // Give the child a moment to see SessionEnd and terminate itself
            // before we drop our reference to its Process.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if session.process.isRunning { session.process.terminate() }
            }
            return
        }

        let session = sessions[sessionID] ?? spawnSession(sessionID: sessionID, cwd: event.cwd)
        guard let session else { return }
        if let pane = event.tmuxPane {
            session.tmuxPane = pane
            fputs("[dockling] session \(sessionID) tmux pane -> \(pane)\n", stderr)
        }
        forward(rawJSON: rawJSON, to: session.port, attemptsLeft: 5)
    }

    private func spawnSession(sessionID: String, cwd: String?) -> Session? {
        guard let executablePath = Bundle.main.executablePath else {
            fputs("[dockling] could not resolve own executable path to spawn session child\n", stderr)
            return nil
        }
        let port = allocatePort()
        let color = allocateColor()
        let name = projectName(fromCwd: cwd)
        let launchPath = appBundleExecutable(realPath: executablePath, projectName: name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = ["--session", sessionID, "--port", "\(port)", "--color", color, "--name", name]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.sessions.removeValue(forKey: sessionID)
            }
        }

        do {
            try process.run()
        } catch {
            fputs("[dockling] failed to spawn child for session \(sessionID): \(error)\n", stderr)
            return nil
        }

        fputs("[dockling] spawned session \(sessionID) on port \(port), color \(color)\n", stderr)
        let session = Session(process: process, port: port, color: color)
        sessions[sessionID] = session
        return session
    }

    private func projectName(fromCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "DocklingAgent" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "DocklingAgent" : name
    }

    /// Dock/Launch Services identity (the hover tooltip, in particular) is
    /// driven by real bundle metadata (Info.plist's CFBundleName), read at
    /// launch — renaming the process after the fact (via a symlink, or via
    /// ProcessInfo.processName) doesn't reach it; both were tried and
    /// confirmed not to change the tooltip. So this synthesizes a minimal,
    /// throwaway .app bundle per project, with the executable inside it just
    /// a symlink to the real binary, and launches that instead.
    private func appBundleExecutable(realPath: String, projectName: String) -> String {
        let bundlesDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("dockling-agent-bundles")
        let bundlePath = (bundlesDir as NSString).appendingPathComponent("\(projectName).app")
        let contentsDir = (bundlePath as NSString).appendingPathComponent("Contents")
        let macOSDir = (contentsDir as NSString).appendingPathComponent("MacOS")
        let executablePath = (macOSDir as NSString).appendingPathComponent("DocklingAgent")
        let infoPlistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")

        let fileManager = FileManager.default
        try? fileManager.createDirectory(atPath: macOSDir, withIntermediateDirectories: true)

        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: executablePath), existingTarget != realPath {
            try? fileManager.removeItem(atPath: executablePath) // stale, e.g. from a rebuilt binary
        }
        if !fileManager.fileExists(atPath: executablePath) {
            do {
                try fileManager.createSymbolicLink(atPath: executablePath, withDestinationPath: realPath)
            } catch {
                fputs("[dockling] could not create app bundle for \(projectName), falling back to real path: \(error)\n", stderr)
                return realPath
            }
        }

        let bundleID = "com.dockling.session." + projectName.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let info: [String: Any] = [
            "CFBundleName": projectName,
            "CFBundleDisplayName": projectName,
            "CFBundleExecutable": "DocklingAgent",
            "CFBundleIdentifier": bundleID,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
        ]
        if let plistData = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0) {
            try? plistData.write(to: URL(fileURLWithPath: infoPlistPath))
        }

        return executablePath
    }

    private func allocatePort() -> UInt16 {
        let usedPorts = Set(sessions.values.map(\.port))
        while usedPorts.contains(nextPort) { nextPort += 1 }
        defer { nextPort += 1 }
        return nextPort
    }

    /// Random, avoiding colors already used by another currently-active
    /// session. Falls back to a fully random pick (duplicates allowed) once
    /// the pool is exhausted — the decided behavior from DOCKLING_SPEC.md's
    /// character-assignment section.
    private func allocateColor() -> String {
        let usedColors = Set(sessions.values.map(\.color))
        let available = Self.colors.filter { !usedColors.contains($0) }
        return (available.isEmpty ? Self.colors : available).randomElement()!
    }

    /// Freshly spawned children need a beat to bind their listener, so a
    /// forward can arrive before the port is ready; retry briefly rather than
    /// dropping the event that triggered the spawn.
    private func forward(rawJSON: [String: Any], to port: UInt16, attemptsLeft: Int) {
        guard let body = try? JSONSerialization.data(withJSONObject: rawJSON) else { return }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 2

        urlSession.dataTask(with: request) { [weak self] _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if !ok, attemptsLeft > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.forward(rawJSON: rawJSON, to: port, attemptsLeft: attemptsLeft - 1)
                }
            } else if !ok {
                fputs("[dockling] gave up forwarding to port \(port): \(error?.localizedDescription ?? "no response")\n", stderr)
            }
        }.resume()
    }
}

func runDispatcher(port: UInt16) -> Never {
    let dispatcher = Dispatcher()
    dispatcher.start(onPort: port)
    fputs("[dockling] dispatcher running, well-known port \(port)\n", stderr)
    dispatchMain()
}
