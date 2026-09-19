import Foundation

/// Delivers a reply into a specific tmux pane, as if the user had typed it
/// into that terminal themselves. See DOCKLING_SPEC.md's Phase 3 tmux bridge.
enum TmuxReply {
    static func send(text: String, toPane pane: String) {
        guard !text.isEmpty else { return }
        // Sent as two calls: the text goes through `-l` (literal), so tmux
        // never tries to interpret it as key names (e.g. a reply containing
        // the word "Enter" must not be parsed as the Enter key); the actual
        // Enter keystroke is sent separately, non-literal, right after.
        sendKeys(["-l", "--", text], toPane: pane)
        sendKeys(["Enter"], toPane: pane)
    }

    private static func sendKeys(_ args: [String], toPane pane: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "send-keys", "-t", pane] + args
        do {
            try process.run()
        } catch {
            fputs("[dockling] tmux send-keys failed: \(error)\n", stderr)
        }
    }
}
