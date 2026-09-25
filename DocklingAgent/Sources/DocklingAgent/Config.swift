import Foundation

/// User-level feature toggles, read once at process startup (dispatcher and
/// every session child each load their own copy, same pattern as
/// DocklingSecret). Missing file, missing keys, or an unparsable file all
/// fall back to `.default` — there's nothing to set up for the common case.
struct DocklingConfig {
    var subagentDucks: Bool
    // Split in two rather than one blanket toggle: the "ready" cue (Stop)
    // and the "awaiting input" cue (Notification) are different enough in
    // purpose — one's a passive "done" ping, the other's an "I need you"
    // alert — that someone may want only one of them.
    var soundEffectsReady: Bool
    var soundEffectsAwaitingInput: Bool

    static let `default` = DocklingConfig(subagentDucks: true, soundEffectsReady: true, soundEffectsAwaitingInput: true)

    private struct Raw: Decodable {
        let subagentDucks: Bool?
        let soundEffectsReady: Bool?
        let soundEffectsAwaitingInput: Bool?

        enum CodingKeys: String, CodingKey {
            case subagentDucks = "subagent_ducks"
            case soundEffectsReady = "sound_effects_ready"
            case soundEffectsAwaitingInput = "sound_effects_awaiting_input"
        }
    }

    private static let path = (((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("config.json"))

    static func load() -> DocklingConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            return .default
        }
        return DocklingConfig(
            subagentDucks: raw.subagentDucks ?? true,
            soundEffectsReady: raw.soundEffectsReady ?? true,
            soundEffectsAwaitingInput: raw.soundEffectsAwaitingInput ?? true
        )
    }

    /// Used by the settings window to persist the user's choices. Always
    /// writes the full set of keys this struct knows about — a hand-added
    /// key it doesn't know about would be lost on the next save from here,
    /// acceptable since this file's only other writer is a person
    /// hand-editing it directly (per this file's own top-level doc comment).
    /// A leftover `focus_vscode_on_click` key from before that feature was
    /// removed is silently dropped by Raw's decoder and never written back.
    func save() {
        let dict: [String: Any] = [
            "subagent_ducks": subagentDucks,
            "sound_effects_ready": soundEffectsReady,
            "sound_effects_awaiting_input": soundEffectsAwaitingInput,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }
}
