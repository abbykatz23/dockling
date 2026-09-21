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
///  - A single cached player per name still cut a sound short if the same
///    sound fired twice in quick succession (two fast turns back to back,
///    say): the second call's `currentTime = 0` yanked the first call's
///    still-playing instance back to the start, discarding whatever was
///    left of it. A small round-robin pool per name (see `poolSize`) gives
///    overlapping triggers their own instance instead of fighting over one.
enum SoundPlayer {
    private static let installedDir = ((((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("resources") as NSString)
        .appendingPathComponent("Sounds"))

    // Every sound Dockling currently triggers — warmUp() primes all of them
    // up front rather than waiting for whichever fires first.
    private static let knownNames = ["ready_dockling", "input_needed_dockling"]
    // However many of the same sound could plausibly overlap at once — not
    // meant to handle unbounded bursts, just enough that two (or a few)
    // quick retriggers each get a clean, uninterrupted playback.
    private static let poolSize = 3

    private static var pools: [String: [AVAudioPlayer]] = [:]
    private static var nextIndex: [String: Int] = [:]

    private static func pool(for name: String) -> [AVAudioPlayer] {
        if let cached = pools[name] { return cached }
        let installedPath = (installedDir as NSString).appendingPathComponent("\(name).mp3")
        let url: URL?
        if FileManager.default.fileExists(atPath: installedPath) {
            url = URL(fileURLWithPath: installedPath)
        } else {
            url = Bundle.module.url(forResource: name, withExtension: "mp3", subdirectory: "Resources/Sounds")
        }
        guard let url else {
            fputs("warning: missing sound asset \(name)\n", stderr)
            return []
        }
        let players = (0..<poolSize).compactMap { _ -> AVAudioPlayer? in
            guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
            player.prepareToPlay()
            return player
        }
        pools[name] = players
        return players
    }

    /// Call once, early (session child startup), so every known sound's
    /// first-play cold start happens now instead of during a real event.
    static func warmUp() {
        for name in knownNames { _ = pool(for: name) }
    }

    static func play(_ name: String) {
        let players = pool(for: name)
        guard !players.isEmpty else { return }
        // Prefer one that's actually free; round-robin as a fallback so a
        // burst beyond poolSize still cycles through every instance rather
        // than hammering just the last one.
        let index = players.firstIndex(where: { !$0.isPlaying }) ?? (nextIndex[name, default: 0] % players.count)
        nextIndex[name] = index + 1

        let player = players[index]
        player.currentTime = 0
        player.play()
    }
}
