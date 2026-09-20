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

    /// Identified by pid rather than a retained `Process` handle — a session
    /// adopted from SessionRegistry.load() on startup was never spawned by
    /// this Dispatcher instance, so there's no Process object for it to hold
    /// in the first place. Liveness/termination go through raw signals
    /// instead of Process.isRunning/.terminate() for the same reason.
    private final class Session {
        var pid: Int32 // mutable: see the "SelfRelaunched" handling in route()
        let port: UInt16
        let color: String
        var tmuxPane: String? // learned from the SessionStart command hook, if any

        init(pid: Int32, port: UInt16, color: String) {
            self.pid = pid
            self.port = port
            self.color = color
        }

        var isAlive: Bool { SessionRegistry.isAlive(pid: pid) }
        func terminate() { kill(pid, SIGTERM) }
    }

    private var sessions: [String: Session] = [:]
    // Randomized rather than a fixed base: even with startup reconciliation
    // below, this stays a useful second line of defense.
    private var nextPort: UInt16 = UInt16.random(in: 20000...60000)
    private let urlSession = URLSession(configuration: .ephemeral)
    private var server: HookServer? // must be retained — see the bug this fixed below

    func start(onPort port: UInt16) {
        reconcileWithRunningChildren()

        let server = HookServer(port: port, expectedToken: sharedSecret) { [weak self] rawJSON, event in
            self?.route(rawJSON: rawJSON, event: event)
        }
        server.start()
        self.server = server
    }

    /// Adopts still-running children left behind by a previous dispatcher
    /// process (manual restart, or an automatic launchd KeepAlive restart
    /// after a crash) instead of spawning a duplicate the next time each
    /// session fires a hook. Anything in the registry that's no longer alive
    /// is just dropped.
    private func reconcileWithRunningChildren() {
        let registry = SessionRegistry.load()
        for (sessionID, entry) in registry where SessionRegistry.isAlive(pid: entry.pid) {
            sessions[sessionID] = Session(pid: entry.pid, port: entry.port, color: entry.color)
            fputs("[dockling] adopted still-running session \(sessionID) on port \(entry.port), color \(entry.color)\n", stderr)
        }
        persistRegistry()
    }

    private func persistRegistry() {
        let entries = sessions.mapValues { SessionRegistry.Entry(pid: $0.pid, port: $0.port, color: $0.color) }
        SessionRegistry.save(entries)
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
            persistRegistry()
            // Give the child a moment to see SessionEnd and terminate itself
            // before force-terminating it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if session.isAlive { session.terminate() }
            }
            return
        }

        // A session child relaunches itself under a new pid, same port, to
        // reclaim the rightmost Dock position after a new subagent baby
        // joins (see SessionChild.swift's scheduleRelaunch()). She notifies
        // us so this doesn't look like the session dying to the liveness
        // check just below — otherwise the very next event for her would
        // find her old (now-dead) pid, conclude she'd crashed, and spawn a
        // completely fresh replacement that's lost track of her babies.
        if event.name == "SelfRelaunched", let newPid = rawJSON["new_pid"] as? Int {
            sessions[sessionID]?.pid = Int32(newPid)
            persistRegistry()
            return
        }

        // A session child asking us to raise the VS Code window for her
        // project on click — done here rather than in the child itself
        // since Accessibility permission is granted per-binary, and every
        // session runs as a distinct synthesized .app bundle; the
        // dispatcher is the one stable process, so this is a one-time grant
        // instead of one per project.
        if event.name == "FocusVSCodeWindow", let cwd = rawJSON["cwd"] as? String {
            WindowFocus.focusVSCodeWindow(forCwd: cwd)
            return
        }

        if let existing = sessions[sessionID], !existing.isAlive {
            fputs("[dockling] session \(sessionID)'s child is no longer alive, respawning\n", stderr)
            sessions.removeValue(forKey: sessionID)
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
        let port = allocatePort()
        let color = resolveColor(forCwd: cwd)
        let name = projectName(fromCwd: cwd)

        guard let pid = ChildProcessLauncher.spawn(session: sessionID, port: port, color: color, name: name) else {
            return nil
        }

        fputs("[dockling] spawned session \(sessionID) on port \(port), color \(color)\n", stderr)
        let session = Session(pid: pid, port: port, color: color)
        sessions[sessionID] = session
        persistRegistry()
        return session
    }

    private func projectName(fromCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return "DocklingAgent" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "DocklingAgent" : name
    }

    private func allocatePort() -> UInt16 {
        let usedPorts = Set(sessions.values.map(\.port))
        while usedPorts.contains(nextPort) { nextPort += 1 }
        defer { nextPort += 1 }
        return nextPort
    }

    /// Resolves a project's color per DOCKLING_SPEC.md's character-assignment
    /// section, in priority order:
    /// 1. A project-local `.dockling` dotfile pin — always wins, even over a
    ///    previously persisted assignment (lets a team check in a fixed
    ///    character for collaborators).
    /// 2. A color persisted from an earlier run of this same project.
    /// 3. A fresh random pick, avoiding colors already used by another
    ///    currently-active session (falling back to a fully random pick,
    ///    duplicates allowed, once the pool is exhausted) — then persisted
    ///    so it stays stable across future runs.
    private func resolveColor(forCwd cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return allocateColor() }
        let projectPath = (cwd as NSString).standardizingPath

        if let pinned = ProjectColors.pinnedColor(forCwd: projectPath, validColors: Self.colors) {
            return pinned
        }
        if let persisted = ProjectColors.persistedColor(forProjectPath: projectPath), Self.colors.contains(persisted) {
            return persisted
        }

        let color = allocateColor()
        ProjectColors.persist(color: color, forProjectPath: projectPath)
        return color
    }

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
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook?token=\(sharedSecret)")!)
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
    WindowFocus.requestPermissionIfNeeded()

    let dispatcher = Dispatcher()
    dispatcher.start(onPort: port)

    fputs("[dockling] dispatcher running, well-known port \(port)\n", stderr)
    dispatchMain()
}
