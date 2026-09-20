import AVFoundation

/// Plays a short sound effect by name (no extension, e.g. "ready_dockling").
/// Mirrors DockIconController's asset-loading pattern: prefers
/// ~/.dockling/resources/Sounds (installed by `--install`) over Bundle.module,
/// since the latter reads straight out of the repo checkout and would
/// reintroduce the same Downloads/Desktop/Documents permission prompt the
/// icon assets were moved out of Bundle.module to avoid.
///
/// Built on AVAudioPlayer rather than NSSound for two reasons, both found by
/// actually listening to a two-quack effect play too short:
///  - NSSound doesn't keep itself alive for the duration of playback — a
///    version of this that created one per call and let it fall out of scope
///    on return let ARC deallocate it mid-playback at random, cutting it off
///    early. Caching one player per name for the process's whole lifetime
///    (see `players`) sidesteps that entirely: nothing ever deallocates it.
///  - The very first sound played in a fresh process reliably lost its start
///    (CoreAudio's playback engine does one-time init work on first use).
///    `prepareToPlay()` primes that ahead of time — `warmUp()` calls it for
///    every known sound right at session startup, so that cost lands before
///    any real trigger needs the sound, not during it.
enum SoundPlayer {
    private static let installedDir = ((((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("resources") as NSString)
        .appendingPathComponent("Sounds"))

    // Every sound Dockling currently triggers — warmUp() primes all of them
    // up front rather than waiting for whichever fires first.
    private static let knownNames = ["ready_dockling", "input_needed_dockling"]

    private static var players: [String: AVAudioPlayer] = [:]

    private static func loadedPlayer(_ name: String) -> AVAudioPlayer? {
        if let cached = players[name] { return cached }
        let installedPath = (installedDir as NSString).appendingPathComponent("\(name).mp3")
        let player: AVAudioPlayer?
        if FileManager.default.fileExists(atPath: installedPath) {
            player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: installedPath))
        } else {
            player = Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Resources/Sounds")
                .flatMap { try? AVAudioPlayer(contentsOf: $0) }
        }
        guard let player else {
            fputs("warning: missing sound asset \(name)\n", stderr)
            return nil
        }
        player.prepareToPlay()
        players[name] = player
        return player
    }

    /// Call once, early (session child startup), so every known sound's
    /// first-play cold start happens now instead of during a real event.
    static func warmUp() {
        for name in knownNames { _ = loadedPlayer(name) }
    }

    static func play(_ name: String) {
        guard let player = loadedPlayer(name) else { return }
        player.currentTime = 0
        player.play()
    }
}
