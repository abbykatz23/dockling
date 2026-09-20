import Foundation

/// `DocklingAgent --install --repo-root <path>`: does everything install.sh
/// used to shell out to jq/openssl for, natively — so setup needs nothing
/// beyond the Swift toolchain already required to build this binary at all.
/// Registers Dockling's hooks into the user-level ~/.claude/settings.json (so
/// every Claude Code session on the machine reports in, not just sessions
/// run from inside this repo) via a clean merge: re-running this is always
/// safe, and it never touches any hook it didn't itself add, for this or any
/// other event. See DOCKLING_SPEC.md's Security & Privacy section ("Hook
/// installation ... must be a clean merge").
enum Installer {
    static func run(repoRoot: String) {
        let token = DocklingSecret.load()
        print("Using Dockling secret at \(DocklingSecret.path)")

        let dockletHooksDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("hooks")
        let installedScriptPath = (dockletHooksDir as NSString).appendingPathComponent("report_session_start.sh")
        let sourceScriptPath = (((repoRoot as NSString).appendingPathComponent(".claude") as NSString)
            .appendingPathComponent("hooks") as NSString).appendingPathComponent("report_session_start.sh")

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: dockletHooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fileManager.fileExists(atPath: installedScriptPath) {
                try fileManager.removeItem(atPath: installedScriptPath)
            }
            try fileManager.copyItem(atPath: sourceScriptPath, toPath: installedScriptPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScriptPath)
        } catch {
            fputs("error: could not install \(sourceScriptPath) -> \(installedScriptPath): \(error)\n", stderr)
            exit(1)
        }

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
        for event in ["PreToolUse", "PostToolUseFailure", "TaskCompleted", "Notification", "Stop", "StopFailure", "SessionEnd"] {
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
}
