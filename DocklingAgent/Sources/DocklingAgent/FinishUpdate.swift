import Foundation

/// `DocklingAgent --finish-update --source <mountedAppPath> [--target <appPathToAlsoReplace>]`:
/// performs the actual install steps for an in-app update, but crucially as
/// a process launched straight from the just-downloaded, already-verified
/// release — not from whatever process initiated the update. A long-running,
/// already-open Dockling window can't self-correct a bug in its own
/// already-loaded update logic just because a newer build exists on disk;
/// only code that's actually re-executed from that newer build can (learned
/// the hard way: the resource-copy bug this replaces stayed broken across a
/// release that fixed it, for exactly this reason). UpdateInstaller.swift
/// spawns this and waits for it to exit, rather than performing these steps
/// itself.
func runFinishUpdate(sourceAppPath: String, targetAppPath: String?) -> Never {
    do {
        try Installer.installDownloadedUpdate(sourceAppPath: sourceAppPath)
        try LaunchdRegistration.install()

        // `targetAppPath` is whichever bundle path the process that kicked
        // off the update was itself running from (typically
        // /Applications/Dockling.app) — replaced here, not by that original
        // process, for the same reason as above. Distinct from the
        // ~/.dockling copy installDownloadedUpdate just handled above, so
        // skipped if they happen to already be the same path.
        if let targetAppPath, targetAppPath != Installer.installedAppBundlePath {
            // Shares Installer.safeReplace rather than a private duplicate
            // of the same backup-and-restore logic — that shared version
            // also fixes two bugs this one used to have: waitUntilExit()
            // running unconditionally even when xattr failed to launch,
            // and the recovery path's own failures being silently
            // swallowed instead of surfaced.
            try Installer.safeReplace(
                destPath: targetAppPath,
                sourcePath: sourceAppPath,
                chmodPath: (targetAppPath as NSString).appendingPathComponent("Contents/MacOS/DocklingAgent"),
                clearsQuarantine: true
            )
        }

        print("dockling-finish-update-ok")
        exit(0)
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}
