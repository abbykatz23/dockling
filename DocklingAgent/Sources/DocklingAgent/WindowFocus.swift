import ApplicationServices
import AppKit

/// Raises the VS Code window whose title matches a given project, via the
/// Accessibility API — there's no other way to reach a specific window of
/// another app. Lives on the dispatcher specifically, not per-session
/// children: each session runs as its own synthesized .app bundle with a
/// distinct bundle identifier, so granting Accessibility permission there
/// would mean granting it separately for every project. A single stable
/// process means the user grants it once.
enum WindowFocus {
    private static let vsCodeBundleIDs: Set<String> = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    /// Call once, early (dispatcher startup) to surface the system
    /// permission prompt before it's needed for a real click.
    static func requestPermissionIfNeeded() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Finds a VS Code window whose title contains the session's project
    /// folder name and raises it, activating VS Code in the process.
    /// Best-effort: title matching isn't exact (VS Code doesn't expose
    /// which folder a window belongs to any other way), and this silently
    /// does nothing if Accessibility isn't authorized or no matching window
    /// is found — same trade-off as the rest of Dockling's
    /// window-order/positioning code.
    ///
    /// Tries progressively higher ancestors of `cwd` (not just its last
    /// component): a session's cwd is often a subdirectory of the actual
    /// VS Code workspace root (e.g. Claude cd'd into a package within a
    /// monorepo), and VS Code's title always shows the workspace root's
    /// name, not wherever the session happens to be sitting.
    @discardableResult
    static func focusVSCodeWindow(forCwd cwd: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let candidates = ancestorNames(ofCwd: cwd)
        guard !candidates.isEmpty else { return false }

        let vsCodeApps = NSWorkspace.shared.runningApplications.filter { vsCodeBundleIDs.contains($0.bundleIdentifier ?? "") }
        for app in vsCodeApps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = children(of: appElement) else { continue }
            let titledWindows = windows.compactMap { window in stringAttribute(window, kAXTitleAttribute).map { (window, $0) } }

            // Deepest/most-specific candidate first, so a session sitting in
            // a subfolder still prefers that subfolder's own window over an
            // ancestor's, when both happen to be open.
            for candidate in candidates {
                guard let match = titledWindows.first(where: { $0.1.contains(candidate) }) else { continue }
                AXUIElementPerformAction(match.0, kAXRaiseAction as CFString)
                // activate(), not just the AX raise above, is what actually
                // brings VS Code to the true system-wide front over every
                // other app — confirmed by testing an AX-only version, which
                // was fast but only reordered the window within VS Code's
                // own stack rather than bringing VS Code forward globally.
                // This can take ~1s if it triggers a Space switch (VS Code
                // on a different virtual desktop) — that's standard macOS
                // behavior for any Dock icon click in that situation, not
                // something specific to or fixable by Dockling.
                app.activate(options: [])
                return true
            }
        }
        return false
    }

    /// Up to the last 4 path components of `cwd`, deepest first, stopping
    /// well short of generic top-level folders like the username.
    private static func ancestorNames(ofCwd cwd: String) -> [String] {
        let components = (cwd as NSString).pathComponents.filter { $0 != "/" && !$0.isEmpty }
        return Array(components.suffix(4).reversed())
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else { return nil }
        return value as? [AXUIElement]
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
