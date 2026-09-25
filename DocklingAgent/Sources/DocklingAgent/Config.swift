import Foundation

/// User-level feature toggles, read once at process startup (dispatcher and
/// every session child each load their own copy, same pattern as
/// DocklingSecret). Missing file, missing keys, or an unparsable file all
/// fall back to `.default` — there's nothing to set up for the common case.
struct DocklingConfig {
    var subagentDucks: Bool
    var soundEffects: Bool

    static let `default` = DocklingConfig(subagentDucks: true, soundEffects: true)

    private struct Raw: Decodable {
        let subagentDucks: Bool?
        let soundEffects: Bool?

        enum CodingKeys: String, CodingKey {
            case subagentDucks = "subagent_ducks"
            case soundEffects = "sound_effects"
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
        return DocklingConfig(subagentDucks: raw.subagentDucks ?? true, soundEffects: raw.soundEffects ?? true)
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
            "sound_effects": soundEffects,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }
}
