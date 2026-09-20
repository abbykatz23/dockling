import Foundation

enum DockState: String, CaseIterable, Codable {
    case idle
    case bash
    case edit
    case search
    case other
    case awaitingInput = "awaiting-input"
    case error
    case eureka
    case thumbsUp = "thumbs-up"
    case butt
    case committing

    /// Bucket a Claude Code tool name (plus, for Bash, its actual command
    /// text) into one of the v1 tool-state buckets. `toolInput` is only
    /// consulted to tell a `git commit` apart from any other Bash call —
    /// every other bucket is keyed on tool name alone.
    static func bucket(forToolName toolName: String, toolInput: [String: Any]?) -> DockState {
        if toolName == "Bash", let command = toolInput?["command"] as? String, isGitCommit(command) {
            return .committing
        }
        switch toolName {
        case "Bash", "BashOutput", "KillShell":
            return .bash
        case "Edit", "Write", "NotebookEdit", "MultiEdit":
            return .edit
        case "Grep", "Glob", "WebSearch", "WebFetch":
            return .search
        default:
            return .other
        }
    }

    /// Deliberately loose: matches "git" anywhere followed later by "commit"
    /// as a whole word, so `git commit -m "..."`, `git -C path commit ...`,
    /// and `cd path && git commit ...` all match. This is purely cosmetic
    /// (which pose shows), so an occasional false positive/negative has no
    /// real consequence.
    private static func isGitCommit(_ command: String) -> Bool {
        guard let gitRange = command.range(of: #"\bgit\b"#, options: .regularExpression) else { return false }
        return command.range(of: #"\bcommit\b"#, options: [.regularExpression], range: gitRange.upperBound..<command.endIndex) != nil
    }
}
