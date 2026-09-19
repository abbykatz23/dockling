import AppKit

/// Owns the single NSDockTile for this Phase 0 spike and swaps its image per DockState.
final class DockIconController {
    private var cache: [DockState: NSImage] = [:]

    init() {
        for state in DockState.allCases {
            guard let url = Bundle.module.url(forResource: state.rawValue, withExtension: "png", subdirectory: "Resources"),
                  let image = NSImage(contentsOf: url) else {
                fputs("warning: missing icon asset for state \(state.rawValue)\n", stderr)
                continue
            }
            cache[state] = image
        }
    }

    func apply(_ state: DockState) {
        DispatchQueue.main.async {
            guard let image = self.cache[state] else { return }
            NSApp.applicationIconImage = image
            fputs("[dockling] dock icon -> \(state.rawValue)\n", stderr)
        }
    }
}
