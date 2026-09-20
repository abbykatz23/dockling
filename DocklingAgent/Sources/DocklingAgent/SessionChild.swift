import AppKit

/// Runs as a dedicated process for exactly one Claude Code session: owns a
/// single Dock icon (via NSApp.applicationIconImage) and listens on its own
/// port for events the dispatcher forwards to it. Exits when its session ends.
///
/// A "mama" instance (launched by the Dispatcher, `agentID == nil`) also
/// spawns and owns a "baby" duck — another instance of this same process,
/// `agentID` set — per subagent, same color as herself, 80% her size. Events
/// carrying an `agent_id` (present only on a subagent's own tool calls, not
/// the parent session's) are forwarded to that baby's port instead of
/// updating mama's own icon; a baby just applies whatever's forwarded to it
/// directly, exactly like an ordinary session child, since mama has already
/// done the routing. See `relaunchFamily()` for why and how the whole family
/// periodically relaunches together.
final class SessionChildDelegate: NSObject, NSApplicationDelegate {
    private struct Baby {
        var pid: Int32
        let port: UInt16
        var isFinishing = false
    }

    private let sessionID: String
    private let port: UInt16
    private let color: String
    private let name: String
    private let agentID: String? // nil for mama, set for a baby
    private let parentPort: UInt16 // dispatcher for mama; mama's own port for a baby
    private var isMama: Bool { agentID == nil }

    private let dockIcon: DockIconController
    private var server: HookServer?
    private let urlSession = URLSession(configuration: .ephemeral)
    private var tmuxPane: String? // learned from SessionStart; needed to send a reply via `tmux send-keys`
    private var pendingQuestion: String = "Claude is waiting for your input."
    private var lastToolDescription: String? // remembered from the most recent PreToolUse, since Notification's own message is generic
    private lazy var replyPanel = ReplyPanelController { [weak self] text in
        self?.submitReply(text)
    }

    // Mama-only state (babies never populate these).
    private var babies: [String: Baby] = [:] // agent_id -> baby
    private var babyOrder: [String] = [] // agent_ids in first-seen order, for a stable family layout across relaunches
    private var nextBabyPort: UInt16 = UInt16.random(in: 30000...60000)
    private var relaunchWorkItem: DispatchWorkItem?

    init(sessionID: String, port: UInt16, color: String, name: String, agentID: String?, parentPort: UInt16) {
        self.sessionID = sessionID
        self.port = port
        self.color = color
        self.name = name
        self.agentID = agentID
        self.parentPort = parentPort
        self.dockIcon = DockIconController(color: color, scale: agentID != nil ? 0.8 : 1.0)
    }

    /// Clicking the Dock icon while there are no visible windows routes here.
    /// Only pops the reply panel while actually awaiting input — otherwise a
    /// click just activates the (windowless) app, same as any other Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard dockingConfig.replyPopover, dockIcon.currentState == .awaitingInput else { return true }
        replyPanel.show(question: pendingQuestion, near: NSEvent.mouseLocation)
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
        dockIcon.apply(.thumbsUp)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let handoff = ChildHandoff.consume(forSession: sessionID) {
            // Resuming after a self-relaunch (see relaunchFamily()) —
            // restore what the previous instance was showing/tracking
            // instead of starting fresh at idle.
            tmuxPane = handoff.tmuxPane
            pendingQuestion = handoff.pendingQuestion
            lastToolDescription = handoff.lastToolDescription
            if isMama {
                babies = handoff.babies.mapValues { Baby(pid: $0.pid, port: $0.port) }
                babyOrder = handoff.babyOrder
                fputs("[dockling] session \(sessionID) resumed from handoff with \(babies.count) babies\n", stderr)
            }
            dockIcon.apply(handoff.dockState)
            notifyParentOfNewPid()
        } else {
            dockIcon.apply(.idle)
        }

        fputs("[dockling] session \(sessionID) child started on port \(port), config subagentDucks=\(dockingConfig.subagentDucks) replyPopover=\(dockingConfig.replyPopover)\n", stderr)

        let server = HookServer(port: port, expectedToken: sharedSecret) { [weak self] rawJSON, event in
            self?.handle(rawJSON: rawJSON, event: event)
        }
        server.start()
        self.server = server
    }

    private func handle(rawJSON: [String: Any], event: HookEvent) {
        if isMama, event.name == "SelfRelaunched", let agentID = event.agentID, let newPid = rawJSON["new_pid"] as? Int {
            // One of my babies relaunched herself as part of a family
            // relaunch (see relaunchFamily()) — update my record of her
            // rather than forwarding this on, so a later SubagentHandback or
            // SessionEnd sweep signals the right (current) pid.
            babies[agentID]?.pid = Int32(newPid)
            return
        }

        if isMama, let agentID = event.agentID {
            guard dockingConfig.subagentDucks else { return } // ignore subagent activity entirely when the feature is off — no baby duck, no effect on mama's own icon
            handleBabyEvent(agentID: agentID, agentType: event.agentType, toolName: event.toolName, rawJSON: rawJSON)
            return
        }

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
        case "UserPromptSubmit":
            // Claude Code has no hook for a user-initiated interrupt (Escape
            // mid-tool-call) — confirmed against the hooks docs, not
            // assumed: Stop doesn't fire on interrupts, and there's no
            // separate cancellation event. Without this, an interrupt left
            // the duck stuck showing whatever it was doing right before.
            // UserPromptSubmit reliably fires for the next real prompt
            // regardless of how the previous turn ended, so resetting here
            // means a stuck icon self-heals the moment the user types
            // anything — not an interrupt-specific fix, just the nearest
            // reliable signal that a fresh turn is starting.
            dockIcon.apply(.idle)
        case "RelaunchSelf":
            // Mama asking one of her babies (this process) to relaunch as
            // part of a family relaunch. See relaunchFamily().
            relaunchSelf()
        case "SessionEnd":
            fputs("[dockling] session \(sessionID) ended, exiting\n", stderr)
            for baby in babies.values { kill(baby.pid, SIGTERM) }
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: - Baby (subagent) tracking — mama only

    private func handleBabyEvent(agentID: String, agentType: String?, toolName: String?, rawJSON: [String: Any]) {
        if var baby = babies[agentID] {
            guard !baby.isFinishing else { return }
            if toolName == "SubagentHandback" {
                // The subagent reporting back is the reliable "I'm done"
                // signal (confirmed empirically — Claude Code has no
                // separate SubagentStart/Stop pair we could key off
                // instead). Show a little eureka celebration, matching the
                // main duck's TaskCompleted pose, then remove her shortly
                // after — reusing DockIconController's own hold duration for
                // .eureka rather than guessing a number here.
                baby.isFinishing = true
                babies[agentID] = baby
                forward(rawJSON: ["hook_event_name": "TaskCompleted"], to: baby.port, attemptsLeft: 3)
                let pid = baby.pid
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    kill(pid, SIGTERM)
                    self?.babies.removeValue(forKey: agentID)
                    self?.babyOrder.removeAll { $0 == agentID }
                }
            } else {
                forward(rawJSON: rawJSON, to: baby.port, attemptsLeft: 3)
            }
            return
        }

        // First we've seen of this subagent — spawn her a duck.
        let babyPort = allocateBabyPort()
        let babySession = "\(sessionID)·\(agentID)"
        let babyName = "\(name) · subagent"
        guard let pid = ChildProcessLauncher.spawn(session: babySession, port: babyPort, color: color, name: babyName, agentID: agentID, parentPort: port) else {
            return
        }
        babies[agentID] = Baby(pid: pid, port: babyPort)
        babyOrder.append(agentID)
        fputs("[dockling] session \(sessionID) spawned baby \(agentID) (\(agentType ?? "subagent")) on port \(babyPort)\n", stderr)
        forward(rawJSON: rawJSON, to: babyPort, attemptsLeft: 5)
        scheduleRelaunch()
    }

    private func allocateBabyPort() -> UInt16 {
        let used = Set(babies.values.map(\.port)).union([port])
        while used.contains(nextBabyPort) { nextBabyPort += 1 }
        defer { nextBabyPort += 1 }
        return nextBabyPort
    }

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

    // MARK: - Self-relaunch (Dock ordering trick)

    /// The Dock has no public API to control icon order or grouping — it's
    /// just launch order among running apps. So to keep a family visually
    /// grouped and mama rightmost, the *whole* family relaunches together —
    /// each baby (oldest first) then mama last — becoming the most-recently-
    /// launched block, and so (per observed behavior, not a documented
    /// guarantee) typically landing contiguous at the end. Relaunching mama
    /// alone isn't enough: if another session's family launches in between
    /// two of *this* mama's relaunches, that other family lands wedged in
    /// the middle, splitting this one apart — confirmed by testing.
    /// This causes a more noticeable flicker (every family member blinks,
    /// not just mama) — a deliberate trade-off for guaranteed contiguity.
    /// Debounced so a burst of several new subagents starting together
    /// causes one family relaunch, not one per baby.
    private func scheduleRelaunch() {
        relaunchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.relaunchFamily() }
        relaunchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func relaunchFamily() {
        let orderedIDs = babyOrder.filter { babies[$0] != nil }
        for (index, agentID) in orderedIDs.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.15) { [weak self] in
                guard let baby = self?.babies[agentID], !baby.isFinishing else { return }
                self?.forward(rawJSON: ["hook_event_name": "RelaunchSelf"], to: baby.port, attemptsLeft: 3)
            }
        }
        let mamaDelay = Double(orderedIDs.count) * 0.15 + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + mamaDelay) { [weak self] in
            self?.relaunchSelf()
        }
    }

    private func relaunchSelf() {
        let handoff = ChildHandoff(
            tmuxPane: tmuxPane,
            dockState: dockIcon.currentState ?? .idle,
            pendingQuestion: pendingQuestion,
            lastToolDescription: lastToolDescription,
            babies: babies.mapValues { ChildHandoff.Baby(pid: $0.pid, port: $0.port) },
            babyOrder: babyOrder
        )
        handoff.save(forSession: sessionID)
        fputs("[dockling] session \(sessionID) (agent \(agentID ?? "mama")) relaunching to reclaim Dock position\n", stderr)
        ChildProcessLauncher.spawn(session: sessionID, port: port, color: color, name: name, agentID: agentID, parentPort: parentPort)
        NSApp.terminate(nil)
    }

    /// Tells whoever's tracking this process's pid (the dispatcher for
    /// mama; mama herself for a baby) that it changed, so their own
    /// liveness check doesn't mistake the old, now-dead pid for a crash and
    /// respawn a fresh replacement that's lost track of state. Sent as early
    /// as possible in startup — every moment before this lands is a window
    /// where that race could still happen (best-effort, not fully
    /// eliminable: see relaunchFamily()'s note on the trade-off generally).
    private func notifyParentOfNewPid() {
        var payload: [String: Any] = [
            "hook_event_name": "SelfRelaunched",
            "session_id": sessionID,
            "new_pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        if let agentID { payload["agent_id"] = agentID }
        forward(rawJSON: payload, to: parentPort, attemptsLeft: 10)
    }
}

func runSessionChild(sessionID: String, port: UInt16, color: String, name: String, agentID: String?, parentPort: UInt16) -> Never {
    // Must happen before NSApplication.shared is touched — this is what the
    // Dock's hover tooltip actually shows for a bundle-less app (there's no
    // Info.plist CFBundleName to override otherwise).
    ProcessInfo.processInfo.processName = name

    let delegate = SessionChildDelegate(sessionID: sessionID, port: port, color: color, name: name, agentID: agentID, parentPort: parentPort)
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    exit(0)
}
