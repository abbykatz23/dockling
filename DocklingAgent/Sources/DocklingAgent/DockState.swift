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
    case testing
    // Art not in yet — see generate_dock_icons.swift's poseForState, which
    // deliberately doesn't map this to a source pose yet. Until it does,
    // DockIconController's cache has no image for it, so applying it is a
    // safe no-op (logged, not visually shown) rather than a crash.
    case compressing

    /// Bucket a Claude Code tool name (plus, for Bash, its actual command
    /// text) into one of the v1 tool-state buckets. `toolInput` is only
    /// consulted to tell specific git subcommands and other recognized
    /// command-line tools apart from any other Bash call — every other
    /// bucket is keyed on tool name alone.
    static func bucket(forToolName toolName: String, toolInput: [String: Any]?) -> DockState {
        if toolName == "Bash", let command = toolInput?["command"] as? String {
            if let gitState = gitPoseState(in: command) { return gitState }
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

    // Matches "git" + optional short flags (e.g. "-C path", "--no-pager")
    // immediately followed by one of our three tracked subcommands — NOT a
    // bare search for "commit"/"pull"/"push" anywhere later in the string.
    // That distinction matters for two reasons a fixed-priority "does the
    // command contain X" check got wrong: a chained command like
    // `git add -A && git commit -m "..." && git push` contains both
    // "commit" and "push", so it needs picking between them (this takes
    // whichever git invocation comes last — the culminating action of the
    // chain); and a commit message that happens to mention "push" in plain
    // English (`git commit -m "fix push notification bug"`) must not match
    // "push" at all, since anchoring to right-after-"git" means a stray
    // word inside a quoted argument was never preceded by "git" in the
    // first place.
    private static let gitPoseRegex = try! NSRegularExpression(
        pattern: #"\bgit\s+(?:-{1,2}[A-Za-z-]+(?:[= ]\S+)?\s+)*(commit|pull|push)\b"#
    )

    private static func gitPoseState(in command: String) -> DockState? {
        let fullRange = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = gitPoseRegex.matches(in: command, range: fullRange)
        guard let lastMatch = matches.last, let subcommandRange = Range(lastMatch.range(at: 1), in: command) else { return nil }
        switch command[subcommandRange] {
        case "commit": return .committing
        case "pull": return .pulling
        case "push": return .pushing
        default: return nil
        }
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
