import Foundation

/// Where the user's actual, double-clickable Dockling.app currently lives
/// (e.g. /Applications/Dockling.app) — not Installer.installedAppBundlePath,
/// which is a private, permanent copy under ~/.dockling that exists
/// specifically so launchd has a stable target immune to *this* path moving,
/// being updated in place, or — the reason this file exists — being thrown
/// away entirely.
///
/// Recorded every time the app is opened as a real bundle (see
/// FirstRunApp.swift), so the dispatcher can later notice this location has
/// stopped existing and treat that the way a user clearly means it: as an
/// uninstall. See Dispatcher.swift's periodic check.
enum InstalledAppLocation {
    private static let path = ((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("installed_app_path")

    static func record(_ bundlePath: String) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? bundlePath.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func load() -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}
