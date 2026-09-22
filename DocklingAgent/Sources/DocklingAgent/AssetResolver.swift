import Foundation

/// Shared by DockIconController (icon PNGs), SoundPlayer (sound MP3s),
/// Installer (copying resources to ~/.dockling on first install), and
/// FirstRunApp (customize-step preview icons).
enum AssetResolver {
    private static let installedResourcesDir = (((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("resources"))

    /// SPM's generated `Bundle.module` accessor only ever checks two
    /// places: `Bundle.main`'s own bundle root, or the exact local `.build`
    /// output path baked in at compile time. Neither works for a properly
    /// packaged, signed `.app`: `Bundle.main`'s root for a real `.app` is
    /// its top level, not Contents/Resources, and codesign flat-out rejects
    /// real content sitting outside Contents/ as "unsealed" — confirmed
    /// directly (not a guess): a plain copy of the resource bundle at the
    /// `.app`'s top level, and even a symlink there pointing into
    /// Contents/Resources, both get flagged, and the app crashes (a real
    /// EXC_BREAKPOINT from `Bundle.module`'s own fatalError, not a
    /// Dockling error) the first time anything touches `Bundle.module`.
    /// This checks the one place that's both codesign-valid *and* where
    /// the local dev build's own resource bundle already happens to sit
    /// relative to the executable, so from-source and packaged-release
    /// builds both resolve correctly with no special-casing between them.
    /// Not private: Installer.installResources() needs the bundled copy
    /// specifically (to find what to copy FROM on first install), not
    /// resolveURL's installed-dir-first behavior — checking the installed
    /// dir first there would be pointless (nothing's installed yet) and,
    /// worse, wrong on a reinstall (it'd resolve to the destination it's
    /// about to copy into, not the source to copy from).
    static let resourceBundle: Bundle = {
        let bundleName = "DocklingAgent_DocklingAgent.bundle"
        let executableDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .deletingLastPathComponent()
        let candidates = [
            // Packaged .app: Contents/MacOS/DocklingAgent -> ../Resources/<bundle>.
            executableDir.deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent(bundleName),
            // From-source dev build: SPM places the bundle right next to
            // the built executable, no Contents/ involved at all.
            executableDir.appendingPathComponent(bundleName),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        fatalError("could not locate \(bundleName) near \(executableDir.path)")
    }()

    /// Prefers ~/.dockling/resources/<subdir>/<name>.<ext> (installed by
    /// `--install`) over the bundled copy above: the latter reads straight
    /// out of the repo checkout's .build folder in a dev build, which
    /// triggers a macOS permission prompt every time if the repo happens to
    /// live under Downloads, Desktop, or Documents. The bundled copy stays
    /// as a fallback so a debug build (or the installer itself, on a
    /// genuinely fresh system) still works before `--install` has ever run.
    static func resolveURL(name: String, ext: String, subdir: String) -> URL? {
        let installedPath = ((installedResourcesDir as NSString)
            .appendingPathComponent(subdir) as NSString)
            .appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: installedPath) {
            return URL(fileURLWithPath: installedPath)
        }
        return resourceBundle.url(forResource: name, withExtension: ext, subdirectory: "Resources/\(subdir)")
    }
}
