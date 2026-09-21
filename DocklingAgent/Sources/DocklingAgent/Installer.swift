import Foundation

/// `DocklingAgent --install`: does everything install.sh used to shell out
/// to jq/openssl for, natively — so setup needs nothing beyond having a
/// built binary in the first place. Registers Dockling's hooks into the
/// user-level ~/.claude/settings.json (so every Claude Code session on the
/// machine reports in, not just sessions run from inside this repo) via a
/// clean merge: re-running this is always safe, and it never touches any
/// hook it didn't itself add, for this or any other event. See
/// DOCKLING_SPEC.md's Security & Privacy section ("Hook installation ...
/// must be a clean merge").
///
/// Deliberately has no dependency on a repo checkout existing anywhere —
/// this is what lets the exact same call serve both `install.sh` (dev,
/// from-source) and the shipped app's own first-run install (FirstRunApp.swift,
/// no repo in sight, possibly not even on disk anywhere permanent yet if
/// launched straight from a mounted DMG). Everything it needs is either
/// inlined below (the hook script) or already compiled into this binary's
/// own resource bundle via SPM (the icon/sound assets, read via Bundle.module).
enum Installer {
    /// A permanent copy of whatever binary is currently running this code,
    /// independent of where that happened to be — most importantly, a DMG
    /// mount (/Volumes/Dockling/...), which stops existing the moment it's
    /// ejected. Both install.sh's dev flow and the shipped app's first-run
    /// install point launchd at this path, not at the original location,
    /// so auto-start keeps working after that.
    static let installedBinaryPath = ((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling/bin") as NSString)
        .appendingPathComponent("DocklingAgent")

    static func run() {
        let token = DocklingSecret.load()
        print("Using Dockling secret at \(DocklingSecret.path)")

        let fileManager = FileManager.default
        installHookScript(fileManager: fileManager)
        installResources(fileManager: fileManager)
        installBinary(fileManager: fileManager)
        mergeHooks(token: token, fileManager: fileManager)
    }

    private static func installHookScript(fileManager: FileManager) {
        let dockletHooksDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("hooks")
        let installedScriptPath = (dockletHooksDir as NSString).appendingPathComponent("report_session_start.sh")
        do {
            try fileManager.createDirectory(atPath: dockletHooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try reportSessionStartScript.write(toFile: installedScriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScriptPath)
        } catch {
            fputs("error: could not install \(installedScriptPath): \(error)\n", stderr)
            exit(1)
        }
    }

    /// Copies the icon/sound assets to ~/.dockling/resources so
    /// DockIconController/SoundPlayer never need to read them from this
    /// binary's own resource bundle at runtime. Without this, every session
    /// child (spawned constantly — once per session, once per subagent)
    /// reads them via Bundle.module — and if that bundle happens to sit
    /// under Downloads, Desktop, or Documents (a very common place to end up,
    /// whether a repo cloned there or an app someone dragged there instead
    /// of to /Applications), that's a macOS permission prompt on every
    /// single one. ~/.dockling isn't inside any TCC-protected folder, so
    /// this makes the prompt structurally impossible regardless of where
    /// the binary sits.
    private static func installResources(fileManager: FileManager) {
        // Derived via the exact same lookup DockIconController/SoundPlayer
        // already use successfully (`subdirectory: "Resources/<color>"`),
        // then walked up out of "yellow" and "Resources" — more reliable
        // than assuming exactly how Bundle.module.resourceURL relates to
        // that subdirectory convention, which isn't the same for every
        // Package.swift resource-bundling configuration.
        guard let oneKnownAsset = Bundle.module.url(forResource: "idle", withExtension: "png", subdirectory: "Resources/yellow") else {
            fputs("error: could not locate bundled icon/sound resources\n", stderr)
            exit(1)
        }
        let sourceDir = oneKnownAsset.deletingLastPathComponent().deletingLastPathComponent()
        let destDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("resources")

        do {
            if fileManager.fileExists(atPath: destDir) {
                try fileManager.removeItem(atPath: destDir)
            }
            try fileManager.copyItem(atPath: sourceDir.path, toPath: destDir)
        } catch {
            fputs("error: could not install icon resources \(sourceDir.path) -> \(destDir): \(error)\n", stderr)
            exit(1)
        }
    }

    private static func installBinary(fileManager: FileManager) {
        guard let runningPath = Bundle.main.executablePath else {
            fputs("error: could not resolve own executable path\n", stderr)
            exit(1)
        }
        let installedDir = (installedBinaryPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: installedDir, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: installedBinaryPath) {
                try fileManager.removeItem(atPath: installedBinaryPath)
            }
            try fileManager.copyItem(atPath: runningPath, toPath: installedBinaryPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinaryPath)
        } catch {
            fputs("error: could not install binary \(runningPath) -> \(installedBinaryPath): \(error)\n", stderr)
            exit(1)
        }
    }

    private static func mergeHooks(token: String, fileManager: FileManager) {
        let installedScriptPath = (((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("hooks") as NSString).appendingPathComponent("report_session_start.sh")
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.json")
        try? fileManager.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        var settings: [String: Any]
        if let data = fileManager.contents(atPath: settingsPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        } else {
            settings = [:]
        }
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        hooks["SessionStart"] = mergedGroups(
            existing: hooks["SessionStart"],
            isDocklingsOwn: { group in matches(group: group, key: "command", contains: "report_session_start.sh") },
            newGroup: ["hooks": [["type": "command", "command": installedScriptPath]]]
        )

        let hookURL = "http://127.0.0.1:\(hookPort)/hook?token=\(token)"
        for event in ["PreToolUse", "PostToolUseFailure", "TaskCompleted", "Notification", "Stop", "StopFailure", "SessionEnd", "UserPromptSubmit", "PreCompact"] {
            hooks[event] = mergedGroups(
                existing: hooks[event],
                isDocklingsOwn: { group in matches(group: group, key: "url", contains: "127.0.0.1:\(hookPort)/hook") },
                newGroup: ["hooks": [["type": "http", "url": hookURL]]]
            )
        }

        settings["hooks"] = hooks

        guard let output = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            fputs("error: could not serialize merged settings.json\n", stderr)
            exit(1)
        }
        do {
            try output.write(to: URL(fileURLWithPath: settingsPath))
            // settings.json now embeds the same secret Secret.swift locks to
            // 0600 — leaving this file at the default umask (typically
            // world-readable) would undermine that protection, since the
            // token is just as usable read out of here.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        } catch {
            fputs("error: could not write \(settingsPath): \(error)\n", stderr)
            exit(1)
        }

        print("Dockling hooks installed into \(settingsPath) — this now applies to every Claude Code session on this machine, not just this repo.")
    }

    /// Drops any prior group in `existing` that looks like Dockling's own
    /// (per `isDocklingsOwn`, checked against every hook in that group — not
    /// by array position, so this is safe even if the user reordered
    /// things), then appends `newGroup`. Everything else — other tools'
    /// hooks for this event, or any other event entirely — is untouched.
    private static func mergedGroups(existing: Any?, isDocklingsOwn: ([String: Any]) -> Bool, newGroup: [String: Any]) -> [Any] {
        let groups = (existing as? [Any]) ?? []
        let kept = groups.filter { group in
            guard let group = group as? [String: Any] else { return true }
            return !isDocklingsOwn(group)
        }
        return kept + [newGroup]
    }

    private static func matches(group: [String: Any], key: String, contains substring: String) -> Bool {
        guard let hookEntries = group["hooks"] as? [[String: Any]] else { return false }
        return hookEntries.contains { entry in
            (entry[key] as? String)?.contains(substring) ?? false
        }
    }

    /// Inlined rather than read from a repo checkout (`.claude/hooks/report_session_start.sh`,
    /// kept in the repo too, as the human-editable source of truth — keep
    /// the two in sync by hand if this ever changes) — the SessionStart
    /// command hook, the one event Dockling needs to run as a real shell
    /// command instead of an "http" hook POST, specifically to read
    /// $TMUX_PANE from the terminal's own environment (an http hook never
    /// touches the terminal's shell, so it can't see this). Forwards Claude
    /// Code's own JSON body unchanged, passing tmux_pane as a URL query
    /// param instead of merging it into the body — deliberately avoids
    /// needing jq (or any other JSON tool) just to run this one script.
    private static let reportSessionStartScript = #"""
    #!/bin/sh
    set -eu

    INPUT=$(cat)
    TOKEN=$(cat "$HOME/.dockling/secret" 2>/dev/null || echo "")
    # $TMUX_PANE is always of the form %<digits> (e.g. "%3"); percent-encode the
    # one character that's special in a URL query rather than pulling in a full
    # urlencode dependency for it.
    PANE_ENCODED=$(printf '%s' "${TMUX_PANE:-}" | sed 's/%/%25/g')

    curl -s -m 2 -X POST "http://127.0.0.1:8765/hook?token=${TOKEN}&tmux_pane=${PANE_ENCODED}" \
      -H 'Content-Type: application/json' \
      -d "$INPUT" > /dev/null || true

    exit 0
    """#
}
