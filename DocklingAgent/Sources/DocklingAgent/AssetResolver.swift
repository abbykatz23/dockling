import Foundation

/// Shared by DockIconController (icon PNGs) and SoundPlayer (sound MP3s).
enum AssetResolver {
    private static let installedResourcesDir = (((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("resources"))

    /// Prefers ~/.dockling/resources/<subdir>/<name>.<ext> (installed by
    /// `--install`) over Bundle.module: the latter reads straight out of the
    /// repo checkout's .build folder, which triggers a macOS permission
    /// prompt every time if the repo happens to live under Downloads,
    /// Desktop, or Documents. Bundle.module stays as a fallback so a debug
    /// build still works before `--install` has ever run.
    static func resolveURL(name: String, ext: String, subdir: String) -> URL? {
        let installedPath = ((installedResourcesDir as NSString)
            .appendingPathComponent(subdir) as NSString)
            .appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: installedPath) {
            return URL(fileURLWithPath: installedPath)
        }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(subdir)")
    }
}
