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
        .thumbsUp: 1.2,
    ]
    private let selfExpiring: Set<DockState> = [.eureka, .thumbsUp]

    /// `scale`: draws each source image smaller within the same canvas size
    /// (rather than shrinking the canvas itself, per the spec's "keep canvas
    /// size ... consistent across all poses" guidance) — used to render a
    /// subagent "baby" duck visibly smaller than her mama, since otherwise
    /// they're identical and unrecognizable as a family at a glance.
    init(color: String, scale: CGFloat = 1.0) {
        let installedDir = ((((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("resources") as NSString)
            .appendingPathComponent(color))

        for state in DockState.allCases {
            // Prefers ~/.dockling/resources (installed by `--install`) over
            // Bundle.module: the latter reads straight out of the repo
            // checkout's .build folder, which triggers a macOS permission
            // prompt every time if the repo happens to live under Downloads,
            // Desktop, or Documents. Bundle.module stays as a fallback so a
            // debug build still works before `--install` has ever run.
            let installedPath = (installedDir as NSString).appendingPathComponent("\(state.rawValue).png")
            let image: NSImage? = FileManager.default.fileExists(atPath: installedPath)
                ? NSImage(contentsOfFile: installedPath)
                : Bundle.module.url(forResource: state.rawValue, withExtension: "png", subdirectory: "Resources/\(color)").flatMap(NSImage.init(contentsOf:))

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
        guard let image = cache[state] else { return }
        NSApp.applicationIconImage = image
        currentState = state
        stateAppliedAt = Date()
        fputs("[dockling] dock icon -> \(state.rawValue)\n", stderr)

        if selfExpiring.contains(state), let hold = minimumHold[state] {
            let work = DispatchWorkItem { [weak self] in self?.setNow(.idle) }
            pendingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        }
    }
}
