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
    case pulling
    case pushing
    // Art not in yet — see generate_dock_icons.swift's poseForState, which
    // deliberately doesn't map these to a source pose yet. Until it does,
    // DockIconController's cache has no image for either, so applying them
    // is a safe no-op (logged, not visually shown) rather than a crash.
    case compressing
    case testing

    /// Bucket a Claude Code tool name (plus, for Bash, its actual command
    /// text) into one of the v1 tool-state buckets. `toolInput` is only
    /// consulted to tell specific git subcommands and other recognized
    /// command-line tools apart from any other Bash call — every other
    /// bucket is keyed on tool name alone.
    static func bucket(forToolName toolName: String, toolInput: [String: Any]?) -> DockState {
        if toolName == "Bash", let command = toolInput?["command"] as? String {
            if isGitSubcommand("commit", in: command) { return .committing }
            if isGitSubcommand("pull", in: command) { return .pulling }
            if isGitSubcommand("push", in: command) { return .pushing }
            if isCompressCommand(command) { return .compressing }
            if isTestCommand(command) { return .testing }
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

    /// Deliberately loose: matches "git" anywhere followed later by
    /// `subcommand` as a whole word, so `git commit -m "..."`,
    /// `git -C path pull`, and `cd path && git commit ...` all match. This
    /// is purely cosmetic (which pose shows), so an occasional false
    /// positive/negative has no real consequence.
    private static func isGitSubcommand(_ subcommand: String, in command: String) -> Bool {
        guard let gitRange = command.range(of: #"\bgit\b"#, options: .regularExpression) else { return false }
        return command.range(of: "\\b\(subcommand)\\b", options: [.regularExpression], range: gitRange.upperBound..<command.endIndex) != nil
    }

    private static let compressionCommandNames = [
        "zip", "unzip", "tar", "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz", "zstd", "unzstd", "7z", "7za",
    ]

    private static func isCompressCommand(_ command: String) -> Bool {
        containsCommandWord(compressionCommandNames, in: command)
    }

    private static let testRunnerNames = [
        "pytest", "jest", "vitest", "mocha", "rspec", "phpunit", "tox", "nose2", "ctest",
    ]

    /// Named test runners match anywhere in the command (same as the
    /// compression tools); "<package manager/build tool> test" is checked
    /// separately since "test" alone is too generic a word to match on its
    /// own without real false-positive risk (e.g. a file literally named
    /// "test" in an unrelated command).
    private static func isTestCommand(_ command: String) -> Bool {
        if containsCommandWord(testRunnerNames, in: command) { return true }
        return command.range(of: #"\b(npm|yarn|pnpm|go|cargo|swift|mvn|gradle|make|rake)\s+(run\s+)?test\b"#, options: .regularExpression) != nil
    }

    private static func containsCommandWord(_ names: [String], in command: String) -> Bool {
        names.contains { name in
            command.range(of: "\\b\(name)\\b", options: .regularExpression) != nil
        }
    }
}
