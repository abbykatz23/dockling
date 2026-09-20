import Foundation

/// User-level feature toggles, read once at process startup (dispatcher and
/// every session child each load their own copy, same pattern as
/// DocklingSecret). Missing file, missing keys, or an unparsable file all
/// fall back to the default (everything on) — there's nothing to set up for
/// the common case.
struct DocklingConfig {
    enum CommitPose: String, Decodable {
        case bride
        case groom
        case random
    }

    var subagentDucks: Bool
    var replyPopover: Bool
    var commitPose: CommitPose

    static let `default` = DocklingConfig(subagentDucks: true, replyPopover: true, commitPose: .random)

    private struct Raw: Decodable {
        let subagentDucks: Bool?
        let replyPopover: Bool?
        let commitPose: CommitPose?

        enum CodingKeys: String, CodingKey {
            case subagentDucks = "subagent_ducks"
            case replyPopover = "reply_popover"
            case commitPose = "commit_pose"
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
            replyPopover: raw.replyPopover ?? true,
            commitPose: raw.commitPose ?? .random
        )
    }
}
