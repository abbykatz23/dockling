import Foundation

/// Per-project color persistence, per DOCKLING_SPEC.md's character-assignment
/// section: "Default assignment is random per project, then persisted
/// locally so it stays stable across future runs unless overridden," plus an
/// optional project-local dotfile so a team can check in a fixed character
/// for collaborators.
enum ProjectColors {
    private static let configPath = (((NSHomeDirectory() as NSString)
        .appendingPathComponent(".dockling") as NSString)
        .appendingPathComponent("projects.json"))

    /// A `.dockling` file directly inside the project directory, containing
    /// a single line like `color: green`. Takes priority over any persisted
    /// assignment — this is the explicit pin, not just a remembered default.
    static func pinnedColor(forCwd cwd: String, validColors: [String]) -> String? {
        let dotfilePath = (cwd as NSString).appendingPathComponent(".dockling")
        guard let contents = try? String(contentsOfFile: dotfilePath, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("color:") else { continue }
            let value = trimmed.dropFirst("color:".count).trimmingCharacters(in: .whitespaces).lowercased()
            if validColors.contains(value) { return value }
        }
        return nil
    }

    /// The color persisted from a previous run for this project path, if any.
    static func persistedColor(forProjectPath path: String) -> String? {
        loadAll()[path]
    }

    /// Remembers `color` for `path` so future runs reuse it, per the spec's
    /// "persisted locally so it stays stable across future runs" behavior.
    static func persist(color: String, forProjectPath path: String) {
        var all = loadAll()
        guard all[path] != color else { return }
        all[path] = color
        save(all)
    }

    private static func loadAll() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return json
    }

    private static func save(_ all: [String: String]) {
        let directory = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: configPath))
    }
}
