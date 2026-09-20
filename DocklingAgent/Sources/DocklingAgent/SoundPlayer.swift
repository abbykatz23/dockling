import AppKit

/// Plays a short sound effect by name (no extension, e.g. "ready_dockling").
/// Mirrors DockIconController's asset-loading pattern: prefers
/// ~/.dockling/resources/Sounds (installed by `--install`) over Bundle.module,
/// since the latter reads straight out of the repo checkout and would
/// reintroduce the same Downloads/Desktop/Documents permission prompt the
/// icon assets were moved out of Bundle.module to avoid.
enum SoundPlayer {
    private static let installedDir = ((((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("resources") as NSString)
        .appendingPathComponent("Sounds"))

    /// A fresh NSSound per call, rather than one cached/reused instance —
    /// simplest way to let overlapping triggers (e.g. two sessions going
    /// idle around the same time) each play independently without one
    /// call's playback state stepping on another's.
    static func play(_ name: String) {
        let installedPath = (installedDir as NSString).appendingPathComponent("\(name).mp3")
        let sound: NSSound?
        if FileManager.default.fileExists(atPath: installedPath) {
            sound = NSSound(contentsOfFile: installedPath, byReference: false)
        } else {
            sound = Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Resources/Sounds")
                .flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        guard let sound else {
            fputs("warning: missing sound asset \(name)\n", stderr)
            return
        }
        sound.play()
    }
}
