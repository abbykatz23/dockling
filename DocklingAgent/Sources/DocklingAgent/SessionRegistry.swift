import Foundation

/// Persists the dispatcher's session table (pid, port, color per session) to
/// disk, so a dispatcher restart — whether manual, or automatic under a
/// launchd KeepAlive crash-restart — can reconcile with children that are
/// still actually running instead of blindly spawning a duplicate for every
/// active session. Without this, every restart orphaned one duck per active
/// session (still functioning, just no longer tracked) and spawned a fresh
/// one alongside it the next time that session fired a hook.
enum SessionRegistry {
    struct Entry: Codable {
        let pid: Int32
        let port: UInt16
        let color: String
    }

    private static let path = (((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("sessions.json"))

    static func load() -> [String: Entry] {
        guard let data = FileManager.default.contents(atPath: path),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return entries
    }

    static func save(_ entries: [String: Entry]) {
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// True if a process with this pid exists and is signalable by us. This
    /// doesn't guarantee it's still *our* child (pids get reused eventually),
    /// but that window is narrow enough in practice to accept for avoiding
    /// duplicate ducks across a dispatcher restart.
    static func isAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }
}
