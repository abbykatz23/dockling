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

    /// Bucket a Claude Code tool name into one of the v1 tool-state buckets.
    static func bucket(forToolName toolName: String) -> DockState {
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
}
