# Dockling

A live, per-session duck in your macOS Dock for Claude Code. Every running Claude Code session gets its own Dock icon, and the duck's pose changes in real time with what that session is doing — idle, running a shell command, editing, searching, waiting on you, erroring out, or celebrating a finished task.

See [DOCKLING_SPEC.md](./DOCKLING_SPEC.md) for the full design rationale. This README covers what's actually built and how to run it today.

## What it does

- One Dock icon per active Claude Code session (not one aggregate icon), driven by Claude Code's [hook system](https://docs.claude.com/en/docs/claude-code/hooks).
- Each session's duck gets a random color from a 9-color pool, avoiding colors currently in use by other active sessions; that color is then remembered per project (see [Per-project colors](#per-project-colors)).
- Hovering a Dock icon shows the project name.
- Poses: idle, bash (construction), edit (coding), search (detective), other-tool, awaiting-input, error, eureka (task completed), thumbs-up (a reply was just sent), committing (bride or groom formalwear, for `git commit` — see [Configuration](#configuration)), pulling (fishing, for `git pull`), pushing (box, for `git push`), testing (scientist, for running a test suite — `pytest`, `jest`, `npm test`, and similar), butt (farewell — shown for 1.5s right before the duck exits on session end).
- Sound effects: a short cue plays when a session becomes ready for your next message (any `Stop`, whichever pose shows first), and another when it's specifically waiting on you to answer something (`Notification` → awaiting-input).
- Clicking a duck while it's awaiting input pops open a small reply panel, anchored right above wherever you clicked. Submitting delivers the text into the session's terminal via `tmux send-keys`, and the duck shows a thumbs-up briefly. Can be turned off — see [Configuration](#configuration).
- Each subagent a session spawns gets its own duck too — same color as its parent, 80% her size — that appears while the subagent's working and disappears shortly after it reports back. See [Subagent ("baby") ducks](#subagent-baby-ducks). Can be turned off — see [Configuration](#configuration).

## Requirements

- macOS
- Swift toolchain (Xcode Command Line Tools is enough — `xcode-select --install`) — this is the *only* dependency; setup doesn't need jq, openssl, or anything else installed first.
- `tmux`, only if you want the reply-from-Dock feature (`brew install tmux`)

## Setup

1. **Build and register the hooks.** This wires Dockling into `~/.claude/settings.json` so *every* Claude Code session on your machine reports its state — not just sessions run from inside this repo. It's a clean merge: your existing hooks (for any event, any tool) are left untouched, and re-running this is always safe (it won't create duplicates).

   ```sh
   ./install/install.sh
   ```

   This also generates a per-install secret at `~/.dockling/secret`, required on every hook request so no other local process can spoof an event or pop a fake reply panel.

2. **Run the dispatcher.** This is the one long-lived process; it listens on port 8765 and spawns a child process (and Dock icon) per session.

   ```sh
   ./DocklingAgent/.build/release/DocklingAgent &
   ```

   Or set it up as a `launchd` agent so it starts automatically at login and restarts itself if it ever crashes:

   ```sh
   ./install/install_launchd.sh
   ```

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

## Subagent ("baby") ducks

- The first time a session's subagent makes a tool call, Dockling spawns her a duck: same color as the parent ("mama"), 80% the size, positioned to mama's left.
- When a subagent reports back (its `SubagentHandback` call — the reliable "I'm done" signal; Claude Code doesn't have a separate subagent-start/stop event pair), her duck shows the eureka pose briefly, then disappears.
- The Dock has no public API to control icon order — it's just launch order among running apps, with no way to group or reorder. To keep a family visually together with mama rightmost, the whole family (every current baby, then mama) relaunches itself under a new pid each time a new baby joins, becoming the most-recently-launched block again. This causes a brief visible flicker across the whole family — a deliberate trade-off, chosen over leaving families to get split apart by other sessions' activity in between.
- Each relaunch is best-effort, not a documented Dock guarantee, and only triggers on a *new* baby joining (removing one doesn't reshuffle the rest, since Dock order doesn't need it to).

## Configuration

Create `~/.dockling/config.json` to change any of these (missing keys/file fall back to the defaults below — there's nothing to set up for the common case):

```json
{
  "subagent_ducks": false,
  "reply_popover": false,
  "commit_pose": "bride"
}
```

- `subagent_ducks` (default `true`): when off, subagents don't get their own duck, and their activity has no effect on mama's icon either — it's as if they're invisible. The whole family-relaunch mechanism (see below) also never triggers, since it exists solely to keep babies grouped with mama.
- `reply_popover` (default `true`): when off, clicking an awaiting-input duck does nothing special (same as clicking any other Dock icon) instead of opening the reply panel. The awaiting-input pose itself still shows — you'd just reply directly in the terminal instead.
- `commit_pose` (default `"random"`): which formalwear pose shows while a `git commit` is running — `"bride"`, `"groom"`, or `"random"` (picked once per session/subagent process, not re-rolled on every commit).

Read once at process startup (dispatcher and every session child each load their own copy), so a change takes effect on the next restart, not live.

## Architecture

- **Dispatcher** (`DocklingAgent` run with no args): the one stable process, bound to the well-known hook port. Never appears in the Dock itself. On each new `session_id`, spawns a child process and hands it a dynamically allocated port.
- **Session child** (`DocklingAgent --session <id> --port <port> --color <color> --name <project>`): owns exactly one Dock icon (`NSApp.applicationIconImage`), launched through a synthesized per-project `.app` bundle so the Dock's hover tooltip shows the real project name. Exits when its session ends.
- **Auth**: every hook request (both real Claude Code hooks and the dispatcher's internal forwards to a child) must carry `?token=<secret>` matching `~/.dockling/secret`, or it's rejected.
- **Restart resilience**: the dispatcher persists its session table (pid/port/color per session) to `~/.dockling/sessions.json` and reconciles with it on startup — adopting still-running children instead of spawning duplicates, and dropping anything no longer alive. This is what makes the `launchd` `KeepAlive` restart-on-crash behavior safe. Baby ducks aren't in this registry (only mama tracks her own babies, in-memory) — a dispatcher restart while subagents are active can orphan their ducks, same trade-off the top-level registry exists to avoid.
- **Reply delivery**: the reply panel anchors to wherever you actually clicked (`NSEvent.mouseLocation`), not to an Accessibility-API lookup of the icon's frame — the latter breaks with multiple displays, since macOS mirrors one Dock icon's position across every screen's Dock.
- **Icon assets**: `--install` copies them to `~/.dockling/resources`, and every Dock icon loads from there rather than from inside the repo checkout. Loading straight out of the checkout (via SPM's `Bundle.module`) would trigger a macOS permission prompt on every single session/subagent spawn if the repo happens to live under Downloads, Desktop, or Documents — a real risk given how often people clone into Downloads by default.

## Known limitations

- Dev build only: no code signing, notarization, DMG, or Homebrew tap yet — that needs an Apple Developer account. Everything above runs from a local `swift build`.
- No telemetry of any kind (this is intentional, not a gap — see `DOCKLING_SPEC.md`).

## License

MIT — see [LICENSE](./LICENSE).
