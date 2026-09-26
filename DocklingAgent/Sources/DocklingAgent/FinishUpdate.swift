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
            try replaceBundle(at: targetAppPath, withAppAt: sourceAppPath)
        }

        print("dockling-finish-update-ok")
        exit(0)
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
}

/// Swaps `targetPath` for `sourceApp`, preserving the old copy as a `.old`
/// sibling until the new one is fully in place — a crash or error partway
/// through leaves the original recoverable rather than gone. Simpler than
/// replacing a process's own currently-executing bundle (not a concern
/// here: this process runs from `sourceApp`, an unrelated path) — just an
/// ordinary file swap.
private func replaceBundle(at targetPath: String, withAppAt sourceApp: String) throws {
    let fileManager = FileManager.default
    let backupPath = targetPath + ".old"

    if fileManager.fileExists(atPath: backupPath) {
        try? fileManager.removeItem(atPath: backupPath)
    }
    if fileManager.fileExists(atPath: targetPath) {
        try fileManager.moveItem(atPath: targetPath, toPath: backupPath)
    }

    do {
        try fileManager.copyItem(atPath: sourceApp, toPath: targetPath)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: (targetPath as NSString).appendingPathComponent("Contents/MacOS/DocklingAgent"))
        let clearQuarantine = Process()
        clearQuarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        clearQuarantine.arguments = ["-cr", targetPath]
        try? clearQuarantine.run()
        clearQuarantine.waitUntilExit()
        try? fileManager.removeItem(atPath: backupPath)
    } catch {
        try? fileManager.removeItem(atPath: targetPath)
        if fileManager.fileExists(atPath: backupPath) {
            try? fileManager.moveItem(atPath: backupPath, toPath: targetPath)
        }
        throw error
    }
}
