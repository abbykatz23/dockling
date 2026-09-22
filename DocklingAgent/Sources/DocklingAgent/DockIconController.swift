import AppKit

/// Owns the single NSDockTile for this session's process and swaps its image
/// per DockState. Some states (a milestone like `eureka`, or `error`) are
/// meant to actually be seen, not flash by if another event fires a moment
/// later — those get a minimum display duration. Whatever state was most
/// recently requested during a hold wins once it expires; nothing queues up.
/// A `selfExpiring` state additionally reverts to idle on its own once its
/// hold elapses, if nothing else has applied a new state by then — without
/// this, a celebration pose like eureka would just sit there as the de facto
/// "resting" icon after every turn that did any work, since nothing else
/// necessarily fires again until the user's next message.
final class DockIconController {
    private var cache: [DockState: NSImage] = [:]
    private(set) var currentState: DockState?
    private var stateAppliedAt: Date = .distantPast
    private var pendingWorkItem: DispatchWorkItem?

    private let minimumHold: [DockState: TimeInterval] = [
        .eureka: 1.5,
        .error: 1.5,
        // An Edit tool call itself finishes almost instantly (unlike a real
        // shell command, which naturally holds the bash pose for as long as
        // it runs) — without a floor here, a PreToolUse for whatever the
        // very next tool call is (often a Read right before, or a Bash
        // rebuild right after) overwrites .edit within milliseconds, so the
        // coding duck flashes by too fast to register even during a real
        // editing burst.
        .edit: 0.6,
    ]
    private let selfExpiring: Set<DockState> = [.eureka]

    // A separate timer/slot from pendingWorkItem on purpose: that one holds
    // whichever single delayed-apply is currently in flight (a minimum-hold
    // delay, or a selfExpiring revert), and this one runs alongside it on an
    // entirely different clock (minutes, not seconds) — sharing one slot
    // would mean whichever fires last silently cancels the other.
    private var idleTimer: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 5 * 60

    /// `scale`: draws each source image smaller within the same canvas size
    /// (rather than shrinking the canvas itself, per the spec's "keep canvas
    /// size ... consistent across all poses" guidance) — used to render a
    /// subagent "baby" duck visibly smaller than her mama, since otherwise
    /// they're identical and unrecognizable as a family at a glance.
    init(color: String, scale: CGFloat = 1.0) {
        // .committing has two separate assets (committing-bride.png,
        // committing-groom.png — see generate_dock_icons.swift) rather than
        // one file at its own rawValue; which one actually backs the state
        // is resolved once here, per config, rather than per lookup, so a
        // "random" pick stays the same duck for this whole process's life
        // instead of flip-flopping on every commit.
        let resolvedCommitPose: DocklingConfig.CommitPose = dockingConfig.commitPose == .random
            ? (Bool.random() ? .bride : .groom)
            : dockingConfig.commitPose
        if dockingConfig.commitPose == .random {
            fputs("[dockling] resolved random commit_pose -> \(resolvedCommitPose.rawValue)\n", stderr)
        }

        for state in DockState.allCases {
            let assetName = state == .committing ? "committing-\(resolvedCommitPose.rawValue)" : state.rawValue

            let image = AssetResolver.resolveURL(name: assetName, ext: "png", subdir: color).flatMap(NSImage.init(contentsOf:))

            guard let image else {
                fputs("warning: missing icon asset for state \(state.rawValue) (color \(color))\n", stderr)
                continue
            }
            cache[state] = scale < 1.0 ? Self.scaled(image, by: scale) : image
        }
    }

    private static func scaled(_ image: NSImage, by scale: CGFloat) -> NSImage {
        let canvasSize = image.size
        let drawnSize = NSSize(width: canvasSize.width * scale, height: canvasSize.height * scale)
        // Anchored to the bottom, centered horizontally, rather than dead
        // center — the source art already stands on the bottom of its own
        // canvas, so this keeps a baby standing on the same "ground line" as
        // mama instead of floating mid-icon.
        let origin = NSPoint(x: (canvasSize.width - drawnSize.width) / 2, y: 0)

        let scaledImage = NSImage(size: canvasSize)
        scaledImage.lockFocus()
        image.draw(in: NSRect(origin: origin, size: drawnSize), from: .zero, operation: .sourceOver, fraction: 1.0)
        scaledImage.unlockFocus()
        return scaledImage
    }

    /// Plays the farewell (`butt`) pose shrinking down over `duration`, as if
    /// waddling off toward the horizon, then calls `completion` — used right
    /// before a session's duck actually exits, in place of a plain static
    /// `apply(.butt)`. Bypasses the normal apply()/minimumHold machinery
    /// entirely, since nothing will (or needs to) call apply() again before
    /// the process terminates right after.
    func playFarewell(duration: TimeInterval = 1.5, completion: @escaping () -> Void) {
        // A still-pending selfExpiring auto-revert (e.g. eureka from a
        // Stop just before this SessionEnd) would otherwise fire mid-
        // animation and flash the icon back to idle for a frame before the
        // next farewell frame overwrites it again.
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        idleTimer?.cancel()
        idleTimer = nil

        guard let baseImage = cache[.butt] else {
            completion()
            return
        }
        fputs("[dockling] dock icon -> butt (farewell)\n", stderr)

        let frameCount = 14
        let minScale: CGFloat = 0.12
        let frames = (0..<frameCount).map { index -> NSImage in
            let t = CGFloat(index) / CGFloat(frameCount - 1)
            let scale = 1.0 - t * (1.0 - minScale)
            return Self.scaled(baseImage, by: scale)
        }
        playFrames(frames, interval: duration / Double(frameCount), completion: completion)
    }

    private func playFrames(_ frames: [NSImage], interval: TimeInterval, completion: @escaping () -> Void) {
        guard let first = frames.first else {
            completion()
            return
        }
        NSApp.applicationIconImage = first
        let remaining = Array(frames.dropFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            if remaining.isEmpty {
                completion()
            } else {
                self?.playFrames(remaining, interval: interval, completion: completion)
            }
        }
    }

    func apply(_ state: DockState) {
        DispatchQueue.main.async {
            self.pendingWorkItem?.cancel()

            let holdRequired = self.currentState.flatMap { self.minimumHold[$0] } ?? 0
            let remaining = holdRequired - Date().timeIntervalSince(self.stateAppliedAt)
            if remaining > 0 {
                let work = DispatchWorkItem { [weak self] in self?.setNow(state) }
                self.pendingWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            } else {
                self.setNow(state)
            }
        }
    }

    private func setNow(_ state: DockState) {
        // Any state transition attempt — even one with no art yet to show —
        // is real activity, so it always cancels a pending sleepy timeout,
        // not just successful ones.
        idleTimer?.cancel()
        idleTimer = nil

        guard let image = cache[state] else {
            // Logged even though there's no image for it yet (a bucket can
            // be wired up in DockState before its art lands — see
            // DockState.swift's compressing/testing comment) — otherwise a
            // state transition happening at all is invisible, both on
            // screen and in the logs, making it impossible to verify the
            // detection logic before the pose exists to look at.
            fputs("[dockling] dock icon -> \(state.rawValue) (no art yet, no visual change)\n", stderr)
            return
        }
        NSApp.applicationIconImage = image
        currentState = state
        stateAppliedAt = Date()
        fputs("[dockling] dock icon -> \(state.rawValue)\n", stderr)

        if selfExpiring.contains(state), let hold = minimumHold[state] {
            let work = DispatchWorkItem { [weak self] in self?.setNow(.idle) }
            pendingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }

        if state == .idle {
            let work = DispatchWorkItem { [weak self] in self?.setNow(.sleepy) }
            idleTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
        }
    }
}
