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
    // Gates both WindowFocus.requestPermissionIfNeeded() (asked once, at
    // dispatcher startup) and the click-to-focus-VS-Code feature itself —
    // Accessibility is a sensitive-sounding permission with no other use in
    // Dockling, so this is opt-in via FirstRunApp's customize step rather
    // than requested unconditionally and unexplained.
    var focusVSCodeOnClick: Bool

    static let `default` = DocklingConfig(subagentDucks: true, replyPopover: true, commitPose: .random, focusVSCodeOnClick: true)

    private struct Raw: Decodable {
        let subagentDucks: Bool?
        let replyPopover: Bool?
        let commitPose: CommitPose?
        let focusVSCodeOnClick: Bool?

        enum CodingKeys: String, CodingKey {
            case subagentDucks = "subagent_ducks"
            case replyPopover = "reply_popover"
            case commitPose = "commit_pose"
            case focusVSCodeOnClick = "focus_vscode_on_click"
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
            commitPose: raw.commitPose ?? .random,
            focusVSCodeOnClick: raw.focusVSCodeOnClick ?? true
        )
    }

    /// Used by FirstRunApp's customize step to persist the user's choices.
    /// Always writes the full set of keys this struct knows about — a
    /// hand-added key it doesn't know about would be lost on the next save
    /// from here, acceptable since this file's only other writer is a person
    /// hand-editing it directly (per this file's own top-level doc comment).
    func save() {
        let dict: [String: Any] = [
            "subagent_ducks": subagentDucks,
            "reply_popover": replyPopover,
            "commit_pose": commitPose.rawValue,
            "focus_vscode_on_click": focusVSCodeOnClick,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        let directory = (Self.path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }
}
