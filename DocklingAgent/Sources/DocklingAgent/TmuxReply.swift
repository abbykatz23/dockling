import Foundation

/// Delivers a reply into a specific tmux pane, as if the user had typed it
/// into that terminal themselves. See DOCKLING_SPEC.md's Phase 3 tmux bridge.
enum TmuxReply {
    static func send(text: String, toPane pane: String) {
        guard !text.isEmpty else { return }
        // Sent as three calls, each waited on so they land in order:
        // 1. the text, through `-l` (literal) so tmux never tries to interpret
        //    it as key names (e.g. a reply containing the word "Enter" must
        //    not be parsed as the Enter key).
        // 2. the actual Enter keystroke, non-literal, to submit it.
        // 3. Ctrl+U, to clear the now-empty-but-not-visually-reset input line
        //    Claude Code's CLI leaves behind, so the next prompt starts clean.
        sendKeys(["-l", "--", text], toPane: pane)
        sendKeys(["Enter"], toPane: pane)
        sendKeys(["C-u"], toPane: pane)
    }

    private static func sendKeys(_ args: [String], toPane pane: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // -L dockling: shim/claude starts its tmux session on this same
        // dedicated socket, not tmux's default one — targeting the default
        // socket here would silently miss the pane entirely (confirmed:
        // that's exactly the class of bug that motivated giving the shim
        // its own socket in the first place — it must never share a server,
        // and by extension a socket, with any other tmux usage). Keep this
        // name in sync with shim/claude's own `-L dockling` if it ever
        // changes.
        process.arguments = ["tmux", "-L", "dockling", "send-keys", "-t", pane] + args
        do {
            try process.run()
            process.waitUntilExit() // keep the three calls strictly ordered
        } catch {
            fputs("[dockling] tmux send-keys failed: \(error)\n", stderr)
        }
    }
}
