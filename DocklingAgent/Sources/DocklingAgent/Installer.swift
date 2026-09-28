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
/// own SPM resource bundle (the icon/sound assets, read via AssetResolver.resourceBundle).
enum Installer {
    /// A permanent copy of whatever binary is currently running this code,
    /// independent of where that happened to be — most importantly, a DMG
    /// mount (/Volumes/Dockling/...), which stops existing the moment it's
    /// ejected. Both install.sh's dev flow and the shipped app's first-run
    /// install point launchd at this path, not at the original location,
    /// so auto-start keeps working after that.
    ///
    /// For a real .app bundle (the shipped, notarized case), this has to be
    /// the executable *inside a copied-whole bundle*, not a bare extracted
    /// file: codesign embeds a hash of the bundle's Info.plist directly
    /// into a bundle main executable's own signature, so the Info.plist has
    /// to keep sitting right next to it — confirmed directly (not a guess):
    /// copying just the extracted executable out on its own breaks
    /// `codesign --verify` (invalid Info.plist), and the real, shipped
    /// install hit exactly this — the dispatcher got silently SIGKILL'd by
    /// the kernel's own code-integrity enforcement at every launch, with no
    /// duck ever appearing anywhere and nothing useful in the log, since it
    /// never got far enough to write one. For the from-source dev flow (a
    /// bare, non-bundled binary, never wrapped/re-signed as a bundle's main
    /// executable), this is just that single copied file, as before.
    static var installedBinaryPath: String {
        guard isRealAppBundle else {
            return ((NSHomeDirectory() as NSString)
                .appendingPathComponent(".dockling/bin") as NSString)
                .appendingPathComponent("DocklingAgent")
        }
        return ((installedAppBundlePath as NSString)
            .appendingPathComponent("Contents/MacOS") as NSString)
            .appendingPathComponent("DocklingAgent")
    }

    static let installedAppBundlePath = ((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("Dockling.app")

    static var isRealAppBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app") && Bundle.main.infoDictionary != nil
    }

    /// Thrown instead of calling exit() directly on failure — `run()` is
    /// called both as a standalone CLI process (`--install`, where exiting
    /// on error is fine) and as a plain function call from inside
    /// FirstRunApp's own live GUI process (where it is NOT: an abrupt
    /// exit() bypasses NSApplication's normal shutdown, and macOS's crash
    /// reporter treats that as the app having "quit unexpectedly" — a
    /// misleading, scary dialog for what's really just a clean, expected
    /// error). Callers decide what to do with it: main.swift prints and
    /// exits, FirstRunApp shows it as a normal alert via showError().
    // Also LocalizedError, not just CustomStringConvertible: plain Error's
    // own `localizedDescription` bridges to NSError and ignores
    // CustomStringConvertible entirely, which previously surfaced a generic
    // "The operation couldn't be completed" in FirstRunApp's Reinstall-
    // failure alert instead of this type's actual, actionable message.
    struct InstallError: Error, CustomStringConvertible, LocalizedError {
        let description: String
        var errorDescription: String? { description }
    }

    /// Replaces `destPath` with a copy of `sourcePath`, keeping the old copy
    /// as a `.old` sibling until the new one is fully in place — a crash or
    /// error partway through leaves the original recoverable rather than
    /// gone (every direct delete-then-copy in this file used to skip this,
    /// so a mid-copy failure could leave ~/.dockling/resources or
    /// ~/.dockling/Dockling.app entirely missing with no automatic
    /// recovery). Shared with FinishUpdate.swift, which used to duplicate
    /// this same logic for its own bundle-replace step.
    ///
    /// `chmodPath`, if given, gets 0o755 after the copy (the destPath itself
    /// for a bare binary, or the executable *inside* a copied bundle).
    /// `clearsQuarantine` strips the quarantine flag a plain file copy
    /// otherwise carries over from the original download.
    static func safeReplace(destPath: String, sourcePath: String, fileManager: FileManager = .default, chmodPath: String? = nil, clearsQuarantine: Bool = false) throws {
        let backupPath = destPath + ".old"
        if fileManager.fileExists(atPath: backupPath) {
            do {
                try fileManager.removeItem(atPath: backupPath)
            } catch {
                // Surfaced clearly here rather than left to fail confusingly
                // a few lines down at moveItem(destPath, backupPath) with a
                // generic "already exists" error — and, left silent (as a
                // bare try? used to do here), this exact stale leftover
                // would otherwise block every future replace of this same
                // path until someone noticed and removed it by hand.
                throw InstallError(description: "a stale backup exists at \(backupPath) and couldn't be removed: \(error) — remove it manually and retry")
            }
        }
        let hadExisting = fileManager.fileExists(atPath: destPath)
        if hadExisting {
            try fileManager.moveItem(atPath: destPath, toPath: backupPath)
        }

        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
            if let chmodPath {
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chmodPath)
            }
            if clearsQuarantine {
                clearQuarantineFlag(atPath: destPath)
            }
            if hadExisting {
                try? fileManager.removeItem(atPath: backupPath)
            }
        } catch {
            var recoveryError: Error?
            do {
                if fileManager.fileExists(atPath: destPath) {
                    try fileManager.removeItem(atPath: destPath)
                }
                if hadExisting {
                    try fileManager.moveItem(atPath: backupPath, toPath: destPath)
                }
            } catch {
                recoveryError = error
            }
            if let recoveryError {
                // Distinct from the plain re-throw below: this is the "the
                // rollback itself failed" case, where destPath may now be
                // completely missing rather than restored to its prior
                // state — silently swallowing this (as bare try?s used to
                // do here) hid exactly that, with the surfaced error still
                // just describing the original copy failure as if recovery
                // had quietly succeeded.
                throw InstallError(description: "install failed (\(error)) and recovery also failed — \(destPath) may now be missing: \(recoveryError)")
            }
            throw error
        }
    }

    /// A straight file copy carries the quarantine flag over from the
    /// original download — harmless for how launchd execs this directly,
    /// but stripped anyway so nothing about the copy still looks like an
    /// unverified download later. Best-effort: only waits for xattr to
    /// finish if it actually launched, rather than calling waitUntilExit()
    /// unconditionally on a Process that may never have started.
    private static func clearQuarantineFlag(atPath path: String) {
        let clearQuarantine = Process()
        clearQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clearQuarantine.arguments = ["-cr", path]
        if (try? clearQuarantine.run()) != nil {
            clearQuarantine.waitUntilExit()
        }
    }

    static func run() throws {
        let token = DocklingSecret.load()
        print("Using Dockling secret at \(DocklingSecret.path)")

        let fileManager = FileManager.default
        try installHookScript(fileManager: fileManager)
        try installResources(fileManager: fileManager)
        try installBinary(fileManager: fileManager)
        try mergeHooks(token: token, fileManager: fileManager)
    }

    private static func installHookScript(fileManager: FileManager) throws {
        let dockletHooksDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("hooks")
        let installedScriptPath = (dockletHooksDir as NSString).appendingPathComponent("report_session_start.sh")
        do {
            try fileManager.createDirectory(atPath: dockletHooksDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try reportSessionStartScript.write(toFile: installedScriptPath, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedScriptPath)
        } catch {
            throw InstallError(description: "could not install \(installedScriptPath): \(error)")
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
    private static func installResources(fileManager: FileManager) throws {
        // Derived via the exact same lookup DockIconController/SoundPlayer
        // already use successfully (`subdirectory: "Resources/<color>"`),
        // then walked up out of "yellow" and "Resources" — more reliable
        // than assuming exactly how Bundle.module.resourceURL relates to
        // that subdirectory convention, which isn't the same for every
        // Package.swift resource-bundling configuration.
        guard let oneKnownAsset = AssetResolver.resourceBundle?.url(forResource: "idle", withExtension: "png", subdirectory: "Resources/yellow") else {
            throw InstallError(description: "could not locate bundled icon/sound resources")
        }
        let sourceDir = oneKnownAsset.deletingLastPathComponent().deletingLastPathComponent()
        let destDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("resources")

        do {
            try safeReplace(destPath: destDir, sourcePath: sourceDir.path, fileManager: fileManager)
        } catch {
            throw InstallError(description: "could not install icon resources \(sourceDir.path) -> \(destDir): \(error)")
        }
    }

    private static func installBinary(fileManager: FileManager) throws {
        if isRealAppBundle {
            try installAppBundle(fileManager: fileManager)
        } else {
            try installBareBinary(fileManager: fileManager)
        }
    }

    /// See installedBinaryPath's doc comment — the whole bundle has to be
    /// copied, not just its executable, so the Info.plist a bundle main
    /// executable's own signature is bound to stays right next to it.
    private static func installAppBundle(fileManager: FileManager) throws {
        let bundlePath = Bundle.main.bundlePath
        do {
            try fileManager.createDirectory(atPath: (installedAppBundlePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try safeReplace(destPath: installedAppBundlePath, sourcePath: bundlePath, fileManager: fileManager, chmodPath: installedBinaryPath, clearsQuarantine: true)
        } catch {
            throw InstallError(description: "could not install app bundle \(bundlePath) -> \(installedAppBundlePath): \(error)")
        }
    }

    private static func installBareBinary(fileManager: FileManager) throws {
        guard let runningPath = Bundle.main.executablePath else {
            throw InstallError(description: "could not resolve own executable path")
        }
        let installedDir = (installedBinaryPath as NSString).deletingLastPathComponent
        do {
            try fileManager.createDirectory(atPath: installedDir, withIntermediateDirectories: true)
            try safeReplace(destPath: installedBinaryPath, sourcePath: runningPath, fileManager: fileManager, chmodPath: installedBinaryPath)
        } catch {
            throw InstallError(description: "could not install binary \(runningPath) -> \(installedBinaryPath): \(error)")
        }
    }

    /// The name SPM's resource bundler produces for this target — must stay
    /// in sync with AssetResolver.resourceBundle's own hardcoded copy, since
    /// both are standing in for the fact that SPM's generated Bundle.module
    /// accessor doesn't work in a packaged, signed .app (see that file's own
    /// doc comment for the full story).
    private static let resourceBundleName = "DocklingAgent_DocklingAgent.bundle"

    /// UpdateInstaller's counterpart to `run()`: installs an already-
    /// downloaded, already-signature-verified `Dockling.app` (mounted from a
    /// freshly downloaded release DMG) in place of whatever's currently
    /// installed, instead of installing a copy of *this* process's own
    /// running bundle. `run()`'s installResources()/installBinary() read
    /// from this process's own Bundle.main/AssetResolver.resourceBundle —
    /// exactly wrong here, since the whole point is picking up code newer
    /// than whatever's currently running, not re-copying it.
    static func installDownloadedUpdate(sourceAppPath: String) throws {
        let fileManager = FileManager.default
        try installHookScript(fileManager: fileManager)

        let sourceResourceBundlePath = ((sourceAppPath as NSString)
            .appendingPathComponent("Contents/Resources") as NSString)
            .appendingPathComponent(resourceBundleName)
        // Resolved via a real Bundle lookup (same known-asset-then-walk-up
        // trick installResources() uses below), not hardcoded path math —
        // a hardcoded ".../Resources" guess broke the moment a newer
        // SwiftPM/Xcode toolchain started wrapping this resource bundle in
        // its own proper Contents/Resources/ package structure instead of
        // a flat folder (confirmed happening: installing Xcode changed
        // `xcode-select`'s active toolchain and silently changed this
        // bundle's own internal layout on the very next build). Bundle's
        // own resource resolution understands either layout automatically,
        // which is exactly why installResources() below never broke.
        guard let sourceBundle = Bundle(path: sourceResourceBundlePath),
              let oneKnownAsset = sourceBundle.url(forResource: "idle", withExtension: "png", subdirectory: "Resources/yellow") else {
            throw InstallError(description: "downloaded app is missing \(resourceBundleName) — malformed or incompatible build")
        }
        let sourceResourcesInner = oneKnownAsset.deletingLastPathComponent().deletingLastPathComponent().path
        let destResourcesDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("resources")
        do {
            try safeReplace(destPath: destResourcesDir, sourcePath: sourceResourcesInner, fileManager: fileManager)
        } catch {
            throw InstallError(description: "could not install icon resources \(sourceResourcesInner) -> \(destResourcesDir): \(error)")
        }

        do {
            try fileManager.createDirectory(atPath: (installedAppBundlePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try safeReplace(destPath: installedAppBundlePath, sourcePath: sourceAppPath, fileManager: fileManager, chmodPath: installedBinaryPath, clearsQuarantine: true)
        } catch {
            throw InstallError(description: "could not install app bundle \(sourceAppPath) -> \(installedAppBundlePath): \(error)")
        }

        let token = DocklingSecret.load()
        try mergeHooks(token: token, fileManager: fileManager)
    }

    private static func mergeHooks(token: String, fileManager: FileManager) throws {
        let installedScriptPath = (((NSHomeDirectory() as NSString).appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("hooks") as NSString).appendingPathComponent("report_session_start.sh")
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.json")
        try? fileManager.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

        var settings: [String: Any]
        if let data = fileManager.contents(atPath: settingsPath) {
            // A missing file is the expected first-run case (start fresh) —
            // but a file that *exists* and fails to parse (concurrent write
            // by another tool, a hand-edit typo, a non-object top-level
            // value) is not: silently falling back to [:] here used to mean
            // writing that empty base back out below, permanently
            // discarding every other tool's hooks and settings that were
            // actually in the file. That directly contradicts this
            // function's own "clean merge, never touches anything it
            // didn't add" guarantee, so this now aborts instead.
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw InstallError(description: "\(settingsPath) exists but isn't valid JSON — refusing to merge hooks into it rather than risk overwriting its contents. Fix or remove the file, then retry.")
            }
            settings = parsed
        } else {
            settings = [:]
        }
        let existingHooksValue = settings["hooks"]
        guard existingHooksValue == nil || existingHooksValue is [String: Any] else {
            // Same reasoning as above: settings.json parsed fine overall,
            // but "hooks" itself is some other shape (null, an array, a
            // string) from a hand-edit or another tool's half-finished
            // write. Silently treating that as empty and merging on top —
            // this is *not* the same as removeHooks's own guard for this
            // exact shape, which safely no-ops instead of also risking data
            // loss, since uninstalling has nothing to merge back in.
            throw InstallError(description: "\(settingsPath)'s \"hooks\" value isn't an object — refusing to merge into it rather than risk overwriting its contents. Fix or remove the \"hooks\" key, then retry.")
        }
        var hooks = (existingHooksValue as? [String: Any]) ?? [:]

        hooks["SessionStart"] = mergedGroups(
            existing: hooks["SessionStart"],
            isDocklingsOwn: { group in matches(group: group, key: "command", contains: "report_session_start.sh") },
            newGroup: ["hooks": [["type": "command", "command": installedScriptPath]]]
        )

        let hookURL = "http://127.0.0.1:\(hookPort)\(hookPath)?token=\(token)"
        // SubagentStop was missing from this list entirely — not a matching
        // bug in SessionChild.swift (which does correctly key off it, see
        // handleBabyEvent), but one level more fundamental: Claude Code
        // only ever calls a hook for an event type actually registered
        // here, so with this event never registered, Dockling's hook
        // receiver was never invoked for it at all, for any subagent, ever.
        // Every baby duck's cleanup had no real signal to work from
        // regardless of anything downstream — confirmed by checking a real
        // ~/.claude/settings.json and finding SubagentStop simply absent.
        for event in ["PreToolUse", "PostToolUseFailure", "TaskCompleted", "Notification", "Stop", "StopFailure", "SubagentStop", "SessionEnd", "UserPromptSubmit", "PreCompact"] {
            hooks[event] = mergedGroups(
                existing: hooks[event],
                isDocklingsOwn: isDocklingsHTTPHookGroup,
                newGroup: ["hooks": [["type": "http", "url": hookURL]]]
            )
        }

        settings["hooks"] = hooks

        guard let output = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            throw InstallError(description: "could not serialize merged settings.json")
        }
        do {
            // Atomic, matching installHookScript's own write a few lines
            // away — a plain (non-atomic) write left settings.json
            // truncated/invalid if the process died mid-write (crash,
            // SIGTERM from stopRunningProcesses during a reinstall, power
            // loss, disk full), which the very next mergeHooks run would
            // then refuse to touch per the guard above, rather than being
            // able to recover automatically.
            try output.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            // settings.json now embeds the same secret Secret.swift locks to
            // 0600 — leaving this file at the default umask (typically
            // world-readable) would undermine that protection, since the
            // token is just as usable read out of here.
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsPath)
        } catch {
            throw InstallError(description: "could not write \(settingsPath): \(error)")
        }

        print("Dockling hooks installed into \(settingsPath) — this now applies to every Claude Code session on this machine, not just this repo.")
    }

    /// Drops any prior group in `existing` that looks like Dockling's own
    /// (per `isDocklingsOwn`, checked against every hook in that group — not
    /// by array position, so this is safe even if the user reordered
    /// things), then appends `newGroup`. Everything else — other tools'
    /// hooks for this event, or any other event entirely — is untouched.
    private static func mergedGroups(existing: Any?, isDocklingsOwn: ([String: Any]) -> Bool, newGroup: [String: Any]) -> [Any] {
        withoutDocklingsOwn(existing: existing, isDocklingsOwn: isDocklingsOwn) + [newGroup]
    }

    /// Same filtering `mergedGroups` does, minus the re-append — used by
    /// `uninstall()`, which wants Dockling's groups gone, not replaced.
    private static func withoutDocklingsOwn(existing: Any?, isDocklingsOwn: ([String: Any]) -> Bool) -> [Any] {
        let groups = (existing as? [Any]) ?? []
        return groups.filter { group in
            guard let group = group as? [String: Any] else { return true }
            return !isDocklingsOwn(group)
        }
    }

    private static func matches(group: [String: Any], key: String, contains substring: String) -> Bool {
        guard let hookEntries = group["hooks"] as? [[String: Any]] else { return false }
        return hookEntries.contains { entry in
            (entry[key] as? String)?.contains(substring) ?? false
        }
    }

    // Paths a previous version of Dockling used for this same well-known
    // port, kept so a reinstall/uninstall after a path change (like the
    // "/hook" -> "/dockling-hook" one) still recognizes and replaces/removes
    // the old entry instead of leaving it behind as an orphaned duplicate —
    // confirmed to actually happen, not just theoretical, the first time
    // this path changed. Append here (never remove) whenever hookPath ever
    // changes again.
    private static let legacyHookPaths = ["/hook"]

    /// Shared by mergeHooks and removeHooks: true for an http-hook group
    /// pointing at this (or a former) Dockling hook URL on the well-known
    /// port.
    private static func isDocklingsHTTPHookGroup(_ group: [String: Any]) -> Bool {
        ([hookPath] + legacyHookPaths).contains { path in
            matches(group: group, key: "url", contains: "127.0.0.1:\(hookPort)\(path)")
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

    curl -s -m 2 -X POST "http://127.0.0.1:\#(hookPort)\#(hookPath)?token=${TOKEN}&tmux_pane=${PANE_ENCODED}" \
      -H 'Content-Type: application/json' \
      -d "$INPUT" > /dev/null || true

    exit 0
    """#

    /// `DocklingAgent --uninstall`: the inverse of `run()`. Removes exactly
    /// what `run()` + LaunchdRegistration.install() set up — Dockling's own
    /// hook groups from ~/.claude/settings.json (every other tool's hooks,
    /// and the user's own, are left exactly as found, same guarantee `run()`
    /// gives), the launchd registration, every currently-running Dockling
    /// process (the dispatcher, and any live session/baby duck — these
    /// aren't launchd children, so bootout alone won't touch them), and
    /// finally ~/.dockling itself.
    static func uninstall() {
        let fileManager = FileManager.default
        let hooksRemoved = removeHooks(fileManager: fileManager)
        LaunchdRegistration.uninstall()
        stopRunningProcesses()

        let docklingDir = (NSHomeDirectory() as NSString).appendingPathComponent(".dockling")
        try? fileManager.removeItem(atPath: docklingDir)

        // hooksRemoved is false when settings.json didn't parse, or had no
        // "hooks" object, at the moment this ran — removeHooks safely
        // no-ops rather than risk touching a file it can't make sense of,
        // but a flat, unconditional success message here used to claim
        // hooks were removed regardless, leaving the user believing
        // Claude Code had stopped reporting to Dockling when the hook
        // entries (and the still-listening, now nonexistent port they
        // point at) were actually untouched.
        if hooksRemoved {
            print("Dockling has been uninstalled: hooks removed from ~/.claude/settings.json, background process stopped, ~/.dockling removed.")
        } else {
            print("Dockling has been uninstalled: background process stopped, ~/.dockling removed. ~/.claude/settings.json couldn't be read or had no \"hooks\" object, so nothing there needed removing — check it by hand if Claude Code still seems to be reporting to Dockling.")
        }
    }

    /// Returns whether settings.json actually had something to remove —
    /// `uninstall()`'s own success message depends on this rather than
    /// assuming it always succeeded.
    @discardableResult
    private static func removeHooks(fileManager: FileManager) -> Bool {
        let claudeDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")
        let settingsPath = (claudeDir as NSString).appendingPathComponent("settings.json")
        guard let data = fileManager.contents(atPath: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return false // nothing installed to remove
        }

        hooks["SessionStart"] = withoutDocklingsOwn(
            existing: hooks["SessionStart"],
            isDocklingsOwn: { group in matches(group: group, key: "command", contains: "report_session_start.sh") }
        )
        for event in ["PreToolUse", "PostToolUseFailure", "TaskCompleted", "Notification", "Stop", "StopFailure", "SubagentStop", "SessionEnd", "UserPromptSubmit", "PreCompact"] {
            hooks[event] = withoutDocklingsOwn(
                existing: hooks[event],
                isDocklingsOwn: isDocklingsHTTPHookGroup
            )
        }
        settings["hooks"] = hooks

        guard let output = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? output.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        return true
    }

    /// Every Dockling-spawned process (dispatcher, mama session children,
    /// baby duck children) runs the same binary under the same process name
    /// regardless of which path it was launched through (installed binary
    /// for the dispatcher, a synthesized per-name .app bundle symlink for
    /// everyone else — see ChildProcessLauncher), so matching by name alone
    /// catches all of them in one sweep. Excludes this process's own pid —
    /// this code itself runs inside a "DocklingAgent" process (whether
    /// invoked via --uninstall or from FirstRunApp's own GUI), and killing
    /// itself mid-uninstall would cut this function off before it finishes.
    private static func stopRunningProcesses() {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "DocklingAgent"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        guard (try? pgrep.run()) != nil else { return }
        pgrep.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            guard let pid = Int32(line), pid != myPid else { continue }
            kill(pid, SIGTERM)
        }
    }
}
