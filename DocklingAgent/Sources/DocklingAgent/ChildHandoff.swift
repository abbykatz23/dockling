import Foundation

/// State a session child — mama, or one of her subagent "babies" — hands off
/// to its own replacement when it relaunches itself. Relaunching is how the
/// Dock's icon order (launch order — there's no API to control it directly)
/// gets manipulated to keep a family visually grouped, mama rightmost: see
/// SessionChild.swift's `relaunchFamily()`. Written just before the old
/// process spawns its replacement and calls NSApp.terminate(); read and
/// deleted by the replacement on launch, if present, in place of the normal
/// fresh-start idle state.
struct ChildHandoff: Codable {
    struct Baby: Codable {
        let pid: Int32
        let port: UInt16
    }

    let tmuxPane: String?
    let dockState: DockState
    let pendingQuestion: String
    let lastToolDescription: String?
    let babies: [String: Baby] // agent_id -> baby; empty for a baby (babies don't have babies)
    let babyOrder: [String] // agent_ids in first-seen order, for keeping a relaunched family grouped in a stable order

    private static func path(forSession session: String) -> String {
        (((NSHomeDirectory() as NSString)
            .appendingPathComponent(".dockling") as NSString)
            .appendingPathComponent("handoff-\(session).json"))
    }

    func save(forSession session: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path(forSession: session)))
    }

    /// Reads and deletes the handoff file for `session`, if one exists.
    static func consume(forSession session: String) -> ChildHandoff? {
        let path = path(forSession: session)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        try? FileManager.default.removeItem(atPath: path)
        return try? JSONDecoder().decode(ChildHandoff.self, from: data)
    }
}
