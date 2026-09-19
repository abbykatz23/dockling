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

    init(color: String) {
        for state in DockState.allCases {
            guard let url = Bundle.module.url(forResource: state.rawValue, withExtension: "png", subdirectory: "Resources/\(color)"),
                  let image = NSImage(contentsOf: url) else {
                fputs("warning: missing icon asset for state \(state.rawValue) (color \(color))\n", stderr)
                continue
            }
            cache[state] = image
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
    }
}
