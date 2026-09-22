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
        var timeoutWorkItem: DispatchWorkItem? // see scheduleBabyTimeout
    }

    // SubagentHandback (see handleBabyEvent) is the normal "she's done"
    // signal, but it's occasionally never observed at all for a given
    // agent_id (seen in practice, likely a signal that gets lost around a
    // conversation compaction boundary) — which would otherwise leave her
    // frozen mid-pose forever, with nothing left to ever revisit her. This
    // is the fallback: if mama hears nothing at all for a baby for this
    // long, she cleans her up on her own, same as a real SubagentHandback
    // would. Well above DockIconController's own 5-minute idle timeout —
    // ordinary tool-call quiet stretches shouldn't trip this.
    private let babyTimeout: TimeInterval = 10 * 60

    private let sessionID: String
    private let port: UInt16
    private let color: String
    private let name: String
    private let agentID: String? // nil for mama, set for a baby
    private let parentPort: UInt16 // dispatcher for mama; mama's own port for a baby
    private var isMama: Bool { agentID == nil }

    private let dockIcon: DockIconController
    private var server: HookServer?
    private let hookForwarder = HookForwarder()
    private var tmuxPane: String? // learned from SessionStart; needed to send a reply via `tmux send-keys`
    private var pendingQuestion: String = "Claude is waiting for your input."
    private var lastToolDescription: String? // remembered from the most recent PreToolUse, since Notification's own message is generic
    private var didWorkThisTurn = false // set on PreToolUse, reset on UserPromptSubmit — see the "Stop" case for why
    private var lastCwd: String? // remembered from whichever event last carried one — used to find this project's VS Code window on click
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
    /// If this session has no tmux pane (i.e. isn't a terminal session
    /// wrapped by the shim — most likely the VS Code panel), asks the
    /// dispatcher to raise the matching VS Code window, since Accessibility
    /// permission is only granted there, not per-project. Also pops the
    /// reply panel while actually awaiting input — otherwise a click just
    /// activates the (windowless) app, same as any other Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if dockingConfig.focusVSCodeOnClick, tmuxPane == nil, let cwd = lastCwd {
            hookForwarder.forward(rawJSON: ["hook_event_name": "FocusVSCodeWindow", "session_id": sessionID, "cwd": cwd], to: hookPort, attemptsLeft: 1)
        }

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
        // Primes both sound effects' playback engine now, while a brief
        // delay is invisible — otherwise that one-time cost lands on
        // whichever real Stop/Notification fires first, clipping its start.
        SoundPlayer.warmUp()

        if let handoff = ChildHandoff.consume(forSession: sessionID) {
            // Resuming after a self-relaunch (see relaunchFamily()) —
            // restore what the previous instance was showing/tracking
            // instead of starting fresh at idle.
            tmuxPane = handoff.tmuxPane
            pendingQuestion = handoff.pendingQuestion
            lastToolDescription = handoff.lastToolDescription
            lastCwd = handoff.lastCwd
            if isMama {
                babies = handoff.babies.mapValues { Baby(pid: $0.pid, port: $0.port) }
                babyOrder = handoff.babyOrder
                // A relaunch (the common case — see relaunchFamily()) never
                // carries a live DispatchWorkItem across processes, so every
                // baby's timeout would otherwise just silently stop being
                // watched from here on, the first time mama relaunches.
                for agentID in babies.keys { scheduleBabyTimeout(agentID: agentID) }
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
        if let cwd = event.cwd { lastCwd = cwd }

        if isMama, event.name == "SelfRelaunched", let agentID = event.agentID, let newPid = rawJSON["new_pid"] as? Int {
            // One of my babies relaunched herself as part of a family
            // relaunch (see relaunchFamily()) — update my record of her
            // rather than forwarding this on, so a later SubagentHandback or
            // SessionEnd sweep signals the right (current) pid.
            let oldPid = babies[agentID]?.pid
            babies[agentID]?.pid = Int32(newPid)
            // She was asked to NSApp.terminate() as part of the relaunch,
            // but nothing confirms she actually did — and once her pid is
            // overwritten above, this is the only moment anything could
            // still reach her to check. Without this, an old instance that
            // failed to exit (observed in practice) becomes a permanent
            // orphan: frozen mid-pose, invisible to every future sweep,
            // since nothing tracks her by that pid again. Mirrors the same
            // grace-then-force-kill the dispatcher uses for its own
            // SelfRelaunched handling.
            if let oldPid, oldPid != Int32(newPid) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if SessionRegistry.isAlive(pid: oldPid) { kill(oldPid, SIGTERM) }
                }
            }
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
            didWorkThisTurn = false
            if let pane = event.tmuxPane {
                tmuxPane = pane
                fputs("[dockling] session \(sessionID) learned tmux pane \(pane)\n", stderr)
            }
        case "PreToolUse":
            let bucket = event.toolName.map { DockState.bucket(forToolName: $0, toolInput: event.toolInput) } ?? .other
            dockIcon.apply(bucket)
            lastToolDescription = event.toolDescription
            didWorkThisTurn = true
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
            SoundPlayer.play("input_needed_dockling")
        case "Stop":
            // TaskCompleted (below) only fires for todo-list-style milestones
            // — genuinely rare — so on its own eureka barely showed up.
            // Stop fires after every turn, so this celebrates any turn that
            // actually did something (ran at least one tool), which is a
            // much better match for "did real work, went fine" than either
            // TaskCompleted alone or celebrating literally every turn
            // (including a one-line answer with no tool calls, which
            // wouldn't feel like an accomplishment).
            dockIcon.apply(didWorkThisTurn ? .eureka : .idle)
            didWorkThisTurn = false
            // Played right at Stop, not delayed to match eureka's later
            // auto-revert to idle — "ready for more instructions" is already
            // true the moment Stop fires, whichever pose shows first.
            SoundPlayer.play("ready_dockling")
        case "StopFailure":
            dockIcon.apply(.idle)
            didWorkThisTurn = false
        case "PreCompact":
            // Context compaction and file compression are different things,
            // but "squishing something smaller" is the same idea either way
            // — reuses the same pose rather than needing its own.
            dockIcon.apply(.compressing)
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
            //
            // .other (thinking), not .idle: there's no hook for "the model
            // has started generating" — PreToolUse only fires once Claude
            // actually decides to call a tool, which can be many seconds
            // into a turn (or never, for a pure text reply). Resetting to
            // idle here meant idle was showing for that entire stretch,
            // even though Claude was actively working the whole time.
            // Idle should mean "waiting for you," not "just got a message."
            dockIcon.apply(.other)
            didWorkThisTurn = false
        case "RelaunchSelf":
            // Mama asking one of her babies (this process) to relaunch as
            // part of a family relaunch. See relaunchFamily().
            relaunchSelf()
        case "SessionEnd":
            fputs("[dockling] session \(sessionID) ended, exiting\n", stderr)
            for baby in babies.values { endBaby(port: baby.port, pid: baby.pid) }
            // The dispatcher forwards SessionEnd and then, per its own
            // comment, waits 2s before force-terminating us if we haven't
            // exited on our own — this 1.5s farewell fits comfortably
            // inside that window.
            dockIcon.playFarewell(duration: 1.5) {
                NSApp.terminate(nil)
            }
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
                baby.timeoutWorkItem?.cancel()
                baby.timeoutWorkItem = nil
                babies[agentID] = baby
                hookForwarder.forward(rawJSON: ["hook_event_name": "TaskCompleted"], to: baby.port, attemptsLeft: 3)
                let pid = baby.pid
                let port = baby.port
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
                    self?.endBaby(port: port, pid: pid)
                    self?.babies.removeValue(forKey: agentID)
                    self?.babyOrder.removeAll { $0 == agentID }
                }
            } else {
                hookForwarder.forward(rawJSON: rawJSON, to: baby.port, attemptsLeft: 3)
                scheduleBabyTimeout(agentID: agentID)
            }
            return
        }

        // First we've seen of this subagent — spawn her a duck.
        let babyPort = allocateBabyPort()
        let babySession = "\(sessionID)·\(agentID)"
        let babyName = "\(name) · subagent"
        guard let babyProcess = ChildProcessLauncher.spawn(session: babySession, port: babyPort, color: color, name: babyName, agentID: agentID, parentPort: port) else {
            return
        }
        babies[agentID] = Baby(pid: babyProcess.processIdentifier, port: babyPort)
        babyOrder.append(agentID)
        fputs("[dockling] session \(sessionID) spawned baby \(agentID) (\(agentType ?? "subagent")) on port \(babyPort)\n", stderr)
        hookForwarder.forward(rawJSON: rawJSON, to: babyPort, attemptsLeft: 5)
        scheduleRelaunch()
        scheduleBabyTimeout(agentID: agentID)
    }

    /// (Re)arms the fallback cleanup timer for a baby — see its declaration
    /// for why it exists. Cancels and replaces any timer already pending
    /// for her, same reset-on-activity shape as DockIconController's own
    /// idle/sleepy timer.
    private func scheduleBabyTimeout(agentID: String) {
        babies[agentID]?.timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let baby = self.babies[agentID], !baby.isFinishing else { return }
            fputs("[dockling] session \(self.sessionID) baby \(agentID) went quiet for \(Int(self.babyTimeout))s with no SubagentHandback ever seen, cleaning her up\n", stderr)
            self.endBaby(port: baby.port, pid: baby.pid)
            self.babies.removeValue(forKey: agentID)
            self.babyOrder.removeAll { $0 == agentID }
        }
        babies[agentID]?.timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + babyTimeout, execute: work)
    }

    private func allocateBabyPort() -> UInt16 {
        let used = Set(babies.values.map(\.port)).union([port])
        while used.contains(nextBabyPort) { nextBabyPort += 1 }
        defer { nextBabyPort += 1 }
        return nextBabyPort
    }

    /// Ends a baby gracefully instead of a bare kill(): forwards a
    /// SessionEnd-shaped event so she runs the exact same handling every
    /// session child already has for it (playFarewell(), then
    /// NSApp.terminate()) rather than just vanishing with no warning.
    /// Force-kills after a grace period as a safety net, in case the event
    /// never arrives or she never gets to exit on her own — the same
    /// pattern the dispatcher uses for its own children's SessionEnd.
    private func endBaby(port: UInt16, pid: Int32) {
        hookForwarder.forward(rawJSON: ["hook_event_name": "SessionEnd"], to: port, attemptsLeft: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if SessionRegistry.isAlive(pid: pid) { kill(pid, SIGTERM) }
        }
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
                self?.hookForwarder.forward(rawJSON: ["hook_event_name": "RelaunchSelf"], to: baby.port, attemptsLeft: 3)
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
            lastCwd: lastCwd,
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
        hookForwarder.forward(rawJSON: payload, to: parentPort, attemptsLeft: 10)
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
