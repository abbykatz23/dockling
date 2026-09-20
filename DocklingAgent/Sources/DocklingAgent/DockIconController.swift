import AppKit

/// Owns the single NSDockTile for this session's process and swaps its image
/// per DockState. Some states (a milestone like `eureka`, or `error`) are
/// meant to actually be seen, not flash by if another event fires a moment
/// later — those get a minimum display duration. Whatever state was most
/// recently requested during a hold wins once it expires; nothing queues up.
final class DockIconController {
    private var cache: [DockState: NSImage] = [:]
    private(set) var currentState: DockState?
    private var stateAppliedAt: Date = .distantPast
    private var pendingWorkItem: DispatchWorkItem?

    private let minimumHold: [DockState: TimeInterval] = [
        .eureka: 1.5,
        .error: 1.5,
    ]

    /// `scale`: draws each source image smaller within the same canvas size
    /// (rather than shrinking the canvas itself, per the spec's "keep canvas
    /// size ... consistent across all poses" guidance) — used to render a
    /// subagent "baby" duck visibly smaller than her mama, since otherwise
    /// they're identical and unrecognizable as a family at a glance.
    init(color: String, scale: CGFloat = 1.0) {
        for state in DockState.allCases {
            guard let url = Bundle.module.url(forResource: state.rawValue, withExtension: "png", subdirectory: "Resources/\(color)"),
                  let image = NSImage(contentsOf: url) else {
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
    }
}
