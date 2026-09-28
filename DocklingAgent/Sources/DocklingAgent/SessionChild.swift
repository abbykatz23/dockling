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

    // SubagentStop (see handleBabyEvent) is the normal "she's done" signal,
    // but nothing guarantees every hook fires (a lost signal, a crashed
    // subagent, etc.) — which would otherwise leave her frozen mid-pose
    // forever, with nothing left to ever revisit her. This is the fallback:
    // if mama hears nothing at all for a baby for this long, she cleans her
    // up on her own, same as a real SubagentStop would. Well above
    // DockIconController's own 5-minute idle timeout — ordinary tool-call
    // quiet stretches shouldn't trip this.
    private let babyTimeout: TimeInterval = 10 * 60
    // See the "Stop" case's own comment for why this debounces at all.
    private static let readySoundDebounce: TimeInterval = 5

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
    private var didWorkThisTurn = false // set on PreToolUse, reset on UserPromptSubmit — see the "Stop" case for why
    private var readySoundWorkItem: DispatchWorkItem?

    // Mama-only state (babies never populate these).
    private var babies: [String: Baby] = [:] // agent_id -> baby
    private var babyOrder: [String] = [] // agent_ids in first-seen order, for a stable family layout across relaunches
    // A relaunched baby's old pid (see SelfRelaunched handling below) stops
    // being tracked in `babies` the instant her entry's pid is overwritten
    // with the new one — but the old process isn't actually confirmed gone
    // until the grace-then-SIGTERM check that follows finishes, and
    // occasionally (the leak README documents under Known limitations)
    // never actually dies at all. Counted separately here and included in
    // the baby-duck cap below, so a burst of relaunches — or the
    // not-yet-root-caused leak itself — can't quietly exceed the cap just
    // because `babies.count` only ever reflects one pid per agent_id.
    private var pendingOrphanPids: Set<Int32> = []
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
    /// Always returns false: this process never has a window of its own to
    /// reopen (it's a Dock tile and nothing else). Returning true — AppKit's
    /// default when this isn't implemented at all — told AppKit to run its
    /// own default handling on top of anything we do ourselves, which, with
    /// zero windows, just makes this invisible process itself the system's
    /// frontmost/active app: confirmed causing a real, reported bug (another
    /// window refusing to come to the front afterward) back when this also
    /// raised a matching VS Code window on click, a feature since removed
    /// for being more trouble than it was worth — this false is what's left
    /// of that fix, and still applies with nothing left to trigger it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        false
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

        fputs("[dockling] session \(sessionID) child started on port \(port), config subagentDucks=\(dockingConfig.subagentDucks)\n", stderr)

        let server = HookServer(port: port, expectedToken: sharedSecret, onBindFailureExhausted: { [weak self] in
            // Should be unreachable in practice now that HookServer retries
            // on the real (async) bind-failure signal instead of one that
            // essentially never fired — see its own doc comment. Kept as a
            // last resort rather than removed: a process that can never
            // receive another hook event has nothing left to do, and
            // exiting cleanly here is strictly better than the alternative,
            // which is exactly the leak this whole fix targets — sitting
            // around forever as a frozen, untrackable Dock icon.
            fputs("[dockling] session \(self?.sessionID ?? "?") could not bind its port after repeated attempts, exiting rather than running with no working hook server\n", stderr)
            NSApp.terminate(nil)
        }) { [weak self] rawJSON, event in
            self?.handle(rawJSON: rawJSON, event: event)
        }
        server.start()
        self.server = server
    }

    private func handle(rawJSON: [String: Any], event: HookEvent) {
        if isMama, event.name == "SelfRelaunched", let agentID = event.agentID, let newPid = rawJSON["new_pid"] as? Int {
            // One of my babies relaunched herself as part of a family
            // relaunch (see relaunchFamily()) — update my record of her
            // rather than forwarding this on, so a later SubagentStop or
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
                pendingOrphanPids.insert(oldPid)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                    guard let self else { return }
                    guard SessionRegistry.isAlive(pid: oldPid) else {
                        self.pendingOrphanPids.remove(oldPid)
                        return
                    }
                    kill(oldPid, SIGTERM)
                    // Give the signal a moment to land before deciding
                    // whether she actually exited — if she's still alive
                    // after this, she's the leak documented in the README,
                    // and stays counted so a persistent leak still counts
                    // against the cap instead of becoming invisible to it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, !SessionRegistry.isAlive(pid: oldPid) else { return }
                        self.pendingOrphanPids.remove(oldPid)
                    }
                }
            }
            return
        }

        if isMama, let agentID = event.agentID {
            guard dockingConfig.subagentDucks else { return } // ignore subagent activity entirely when the feature is off — no baby duck, no effect on mama's own icon
            handleBabyEvent(agentID: agentID, agentType: event.agentType, eventName: event.name, rawJSON: rawJSON)
            return
        }

        switch event.name {
        case "SessionStart":
            dockIcon.apply(.idle)
            didWorkThisTurn = false
        case "PreToolUse":
            let bucket = event.toolName.map { DockState.bucket(forToolName: $0, toolInput: event.toolInput) } ?? .other
            dockIcon.apply(bucket)
            didWorkThisTurn = true
        case "PostToolUseFailure":
            dockIcon.apply(.error)
        case "TaskCompleted":
            dockIcon.apply(.eureka)
        case "Notification":
            dockIcon.apply(.awaitingInput)
            // isMama-gated: a subagent can apparently fire her own
            // Notification/Stop events too (confirmed happening in
            // practice — subagent ducks were quacking), forwarded to her
            // the same as any other agent_id-tagged event. Her pose still
            // updates same as always; only the sound is mama-exclusive —
            // one quack per real turn, not one per subagent on top.
            if isMama, dockingConfig.soundEffectsAwaitingInput { SoundPlayer.play("input_needed_dockling") }
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
            // Debounced, not played right at Stop directly — confirmed by
            // direct testing (with logging) that a single turn orchestrating
            // several subagents can produce a real burst of several genuine
            // Stop events on mama's own session before the one final
            // response a person actually sees, each one legitimately real
            // (Claude Code's own docs: Stop fires once per turn — there are
            // just more real turns happening internally than the visible
            // response suggests). Playing a sound on every one of them
            // sounded like a stuck kazoo. Restarting this timer on every
            // Stop and only actually playing once it fires unanswered means
            // only the *last* Stop in a burst ever produces a sound — the
            // moment nothing else follows it, which is the only point
            // "ready for your next message" is actually true. A normal,
            // isolated single-turn interaction still gets a quack, just a
            // couple seconds after Stop instead of immediately — an
            // imperceptible cost for an ambient cue.
            if isMama, dockingConfig.soundEffectsReady {
                readySoundWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    fputs("[dockling] session \(self?.sessionID ?? "?") playing ready_dockling (Stop burst settled)\n", stderr)
                    SoundPlayer.play("ready_dockling")
                }
                readySoundWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.readySoundDebounce, execute: work)
            }
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
            // A pending debounced ready_dockling (see the "Stop" case) has
            // nothing left to be "ready" for once the session is over —
            // without this, a session ended right on the tail of a Stop
            // burst could still quack a couple seconds into its own farewell.
            readySoundWorkItem?.cancel()
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

    private func handleBabyEvent(agentID: String, agentType: String?, eventName: String, rawJSON: [String: Any]) {
        // A subagent that never calls a tool (a trivial task — confirmed
        // happening in practice, not hypothetical) fires exactly one event
        // for its whole life: SubagentStop. Without this check, that lands
        // in the "first time we've seen her" branch below exactly like a
        // real PreToolUse would, spawning her a brand new duck — for a
        // subagent that's already finished — and forwarding the raw
        // SubagentStop to it, which her own switch statement has no case
        // for (default: break), leaving a duck frozen at her initial idle
        // pose until the 10-minute fallback eventually cleans her up. A
        // subagent that never did any visible work has nothing worth
        // showing in the first place, so this skips spawning her a duck at
        // all rather than spawning one just to immediately celebrate and
        // remove it.
        guard !(babies[agentID] == nil && eventName == "SubagentStop") else { return }

        if var baby = babies[agentID] {
            guard !baby.isFinishing else { return }
            if eventName == "SubagentStop" {
                // The real "she's done" signal — confirmed directly against
                // Claude Code's own hook documentation. This used to check
                // `tool_name == "SubagentStop"`, which could never match
                // anything: the real event has no `tool_name` field at all,
                // and its real name is `SubagentStop`, delivered as
                // `hook_event_name` like any other hook. That mismatch meant
                // this branch had never actually fired for any subagent,
                // ever — every baby duck's cleanup was silently falling all
                // the way through to the 10-minute babyTimeout fallback
                // below, which is exactly the "gets stuck" symptom this
                // fixes. Show a little eureka celebration, matching the
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

        // First we've seen of this subagent — spawn her a duck, unless mama
        // already has as many as this session allows. A burst of many
        // subagents at once (seen in practice) otherwise has no ceiling on
        // how many baby ducks pile up in the Dock — capped here rather than
        // in scheduleRelaunch()/the layout code, so an over-the-cap subagent
        // never gets a duck, a port, or a process in the first place. Her
        // own hook events (including eventually SubagentStop) are just
        // dropped from here on, same as the subagentDucks-disabled case
        // above — nothing else about her actual work is affected, only
        // whether she gets a visual.
        //
        // Reloaded fresh from disk rather than using the process-wide
        // `dockingConfig` (loaded once at startup, same as every other
        // setting) — this is the one setting where a stale in-memory copy
        // defeats its own purpose: it's specifically meant to react to an
        // already-crowded Dock, and mama only relaunches (the moment she'd
        // otherwise pick up a new value) when a new baby successfully
        // spawns, which a stuck-on cap prevents from ever happening. The
        // extra disk read only happens here, on a brand-new subagent, not
        // on every forwarded event, so the cost is negligible.
        // pendingOrphanPids.count is included alongside babies.count since a
        // relaunched baby's old pid stops appearing in `babies` before it's
        // actually confirmed gone (see its own declaration above) — without
        // this, a burst of relaunches could let the real number of running
        // baby-duck processes exceed the cap.
        if DocklingConfig.load().limitSubagentDucks, babies.count + pendingOrphanPids.count >= DocklingConfig.maxSubagentDucks {
            return
        }

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
            fputs("[dockling] session \(self.sessionID) baby \(agentID) went quiet for \(Int(self.babyTimeout))s with no SubagentStop ever seen, cleaning her up\n", stderr)
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
        // Long enough to collect a whole burst of subagents starting within
        // a few seconds of each other into one relaunch instead of one per
        // subagent — reported as a real, noticeable UX problem (3 subagents
        // meant rearranging the Dock 3 times in quick succession), and each
        // relaunch is also the one place a real, separate race (see
        // Dispatcher.route()'s liveness-grace handling) can occur, so fewer,
        // less frequent relaunches lowers exposure to that too. Was 0.6s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
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
            dockState: dockIcon.currentState ?? .idle,
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
