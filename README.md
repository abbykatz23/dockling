# Dockling

A live, per-session duck in your macOS Dock for Claude Code. Every running Claude Code session gets its own Dock icon, and the duck's pose changes in real time with what that session is doing — idle, running a shell command, editing, searching, waiting on you, erroring out, or celebrating a finished task.

See [DOCKLING_SPEC.md](./DOCKLING_SPEC.md) for the full design rationale. This README covers what's actually built and how to run it today.

## What it does

- One Dock icon per active Claude Code session (not one aggregate icon), driven by Claude Code's [hook system](https://docs.claude.com/en/docs/claude-code/hooks).
- Each session's duck gets a random color from a 9-color pool, avoiding colors currently in use by other active sessions; that color is then remembered per project (see [Per-project colors](#per-project-colors)).
- Hovering a Dock icon shows the project name.
- Poses: idle, bash, edit, search, other-tool, coding, awaiting-input, error, eureka (task completed).
- Clicking a duck while it's awaiting input pops open a small reply panel, anchored right above wherever you clicked. Submitting delivers the text into the session's terminal via `tmux send-keys`.

## Requirements

- macOS
- Swift toolchain (Xcode Command Line Tools is enough — `xcode-select --install`)
- `jq`, `curl`, `openssl` (all standard on macOS, or `brew install jq`)
- `tmux`, only if you want the reply-from-Dock feature (`brew install tmux`)

## Setup

1. **Register the hooks.** This wires Dockling into `~/.claude/settings.json` so *every* Claude Code session on your machine reports its state — not just sessions run from inside this repo. It's a clean merge: your existing hooks (for any event, any tool) are left untouched, and re-running this is always safe (it won't create duplicates).

   ```sh
   ./install/install.sh
   ```

   This also generates a per-install secret at `~/.dockling/secret`, required on every hook request so no other local process can spoof an event or pop a fake reply panel.

2. **Build and run the dispatcher.** This is the one long-lived process; it listens on port 8765 and spawns a child process (and Dock icon) per session.

   ```sh
   cd DocklingAgent
   swift build
   .build/debug/DocklingAgent &
   ```

   Keep it running (a login item / `launchd` agent is the natural next step here, not yet built — see [Known limitations](#known-limitations)).

3. **Start or continue any Claude Code session.** A duck appears in the Dock once the session's first hook fires (`SessionStart`, or the first tool call in some clients).

### Reply-from-Dock (optional)

The reply popover only works for a session running in a real terminal wrapped in `tmux` — Claude Code's own hook payload doesn't otherwise expose a way to inject text back into a running session. `shim/claude` is a PATH shim that transparently wraps `claude` in a dedicated tmux session (invisible — status bar off, no behavior change) so this works without you having to remember to run `tmux` yourself:

```sh
# put the shim earlier on PATH than the real `claude`
export PATH="/path/to/dockling/shim:$PATH"
```

This doesn't apply to the dedicated Claude Code panel in VS Code (a webview, not a tmux-reachable pane) — you'll still get a duck and live state for those sessions, just not the reply popover.

## Per-project colors

- First session in a project: a color is picked at random, avoiding colors already in use by another currently-active session, then persisted to `~/.dockling/projects.json` keyed by the project's absolute path.
- Every later session in that same project reuses the persisted color, so it stays stable across restarts.
- To pin a color explicitly (e.g. to check a fixed character into a repo for collaborators), add a `.dockling` file at the project root:

  ```
  color: green
  ```

  Valid colors: `yellow`, `blue`, `babyblue`, `gray`, `green`, `lavender`, `orange`, `pink`, `tan`. A dotfile pin always wins over a persisted assignment.

## Architecture

- **Dispatcher** (`DocklingAgent` run with no args): the one stable process, bound to the well-known hook port. Never appears in the Dock itself. On each new `session_id`, spawns a child process and hands it a dynamically allocated port.
- **Session child** (`DocklingAgent --session <id> --port <port> --color <color> --name <project>`): owns exactly one Dock icon (`NSApp.applicationIconImage`), launched through a synthesized per-project `.app` bundle so the Dock's hover tooltip shows the real project name. Exits when its session ends.
- **Auth**: every hook request (both real Claude Code hooks and the dispatcher's internal forwards to a child) must carry `?token=<secret>` matching `~/.dockling/secret`, or it's rejected.
- **Reply delivery**: the reply panel anchors to wherever you actually clicked (`NSEvent.mouseLocation`), not to an Accessibility-API lookup of the icon's frame — the latter breaks with multiple displays, since macOS mirrors one Dock icon's position across every screen's Dock.

## Known limitations

- Dev build only: no code signing, notarization, DMG, or Homebrew tap yet. Everything above runs from a local `swift build`.
- No `launchd` agent yet, so the dispatcher needs to be started by hand each login.
- The dispatcher doesn't persist its in-memory session table across its own restarts. Restarting it mid-session leaves that session's already-running duck as an orphan (still working, just no longer tracked) and spawns a fresh one on the next hook event. Harmless but untidy — avoid restarting the dispatcher while sessions are active if you can.
- No telemetry of any kind (this is intentional, not a gap — see `DOCKLING_SPEC.md`).

## License

Not yet decided.
