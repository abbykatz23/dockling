import Foundation

/// User-level feature toggles, read once at process startup (dispatcher and
/// every session child each load their own copy, same pattern as
/// DocklingSecret). Missing file, missing keys, or an unparsable file all
/// fall back to the default (everything on) — there's nothing to set up for
/// the common case.
struct DocklingConfig {
    var subagentDucks: Bool
    var replyPopover: Bool

    static let `default` = DocklingConfig(subagentDucks: true, replyPopover: true)

    private struct Raw: Decodable {
        let subagentDucks: Bool?
        let replyPopover: Bool?

        enum CodingKeys: String, CodingKey {
            case subagentDucks = "subagent_ducks"
            case replyPopover = "reply_popover"
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
            replyPopover: raw.replyPopover ?? true
        )
    }
}
