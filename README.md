# Dockling

A live, per-session duck in your macOS Dock for Claude Code. Every running Claude Code session gets its own Dock icon, and the duck's pose changes in real time with what that session is doing — idle, running a shell command, editing, searching, waiting on you, erroring out, or celebrating a finished task.

See [DOCKLING_SPEC.md](./DOCKLING_SPEC.md) for the full design rationale. This README covers what's actually built and how to run it today.

## What it does

- One Dock icon per active Claude Code session (not one aggregate icon), driven by Claude Code's [hook system](https://docs.claude.com/en/docs/claude-code/hooks).
- Each session's duck gets a random color from a 9-color pool, avoiding colors currently in use by other active sessions; that color is then remembered per project (see [Per-project colors](#per-project-colors)).
- Hovering a Dock icon shows the project name.
- Poses: idle, bash (construction), edit (coding), search (detective), other-tool, awaiting-input, error, eureka (task completed), committing (bride or groom formalwear, for `git commit` — picked randomly once per session/subagent process, not configurable), pulling (fishing, for `git pull`), pushing (box, for `git push`), testing (scientist, for running a test suite — `pytest`, `jest`, `npm test`, and similar), compressing (squished, for `zip`/`tar`/`gzip`/etc. — also shown when Claude Code compacts its own context), sleepy (pajamas, shown automatically once idle has sat unchanged for 5 minutes — any activity wakes the duck right back up), butt (farewell — shown for 1.5s right before the duck exits on session end).
- Sound effects: a short cue plays when a session becomes ready for your next message (any `Stop`, whichever pose shows first), and another when it's specifically waiting on you to answer something (`Notification` → awaiting-input).
- Each subagent a session spawns gets its own duck too — same color as its parent, 80% her size — that appears while the subagent's working and disappears shortly after it reports back. See [Subagent ("baby") ducks](#subagent-baby-ducks). Can be turned off — see [Configuration](#configuration).

## Requirements

- macOS
- Swift toolchain (Xcode Command Line Tools is enough — `xcode-select --install`), only if building from source (Option B below) — the downloaded DMG (Option A) ships a prebuilt binary and needs nothing beyond macOS itself.

## Setup

### Option A: download (no Terminal, no Swift toolchain)

1. Download the latest signed, notarized DMG from [Releases](https://github.com/abbykatz23/dockling/releases), open it, and drag Dockling to Applications.
2. Double-click Dockling in Applications and click **Install**. This wires Dockling into `~/.claude/settings.json` so *every* Claude Code session on your machine reports its state — not just sessions run from inside a checkout of this repo — and registers it to start automatically at login. Right after, a window opens with your settings (whether to show a baby duck for each subagent) and a key showing what each duck pose means. Opening Dockling again later reopens this same window — settings save immediately as you change them, and it's also where you can Uninstall or Reinstall.
3. Start or continue any Claude Code session. A duck appears in the Dock once the session's first hook fires (`SessionStart`, or the first tool call in some clients).

To uninstall, double-click Dockling in Applications again and click **Uninstall** — see [Uninstalling](#uninstalling).

### Option B: from source

1. **Build and register the hooks.** Same clean-merge guarantee as above: your existing hooks (for any event, any tool) are left untouched, and re-running this is always safe.

   ```sh
   ./install/install.sh
   ```

   This also generates a per-install secret at `~/.dockling/secret`, required on every hook request so no other local process can spoof an event.

2. **Run the dispatcher.** This is the one long-lived process; it listens on port 8765 and spawns a child process (and Dock icon) per session.

   ```sh
   ~/.dockling/bin/DocklingAgent --dispatcher &
   ```

   Or set it up as a `launchd` agent so it starts automatically at login and restarts itself if it ever crashes:

   ```sh
   ./install/install_launchd.sh
   ```

3. **Start or continue any Claude Code session.** A duck appears in the Dock once the session's first hook fires (`SessionStart`, or the first tool call in some clients).

   To uninstall:

   ```sh
   ~/.dockling/bin/DocklingAgent --uninstall
   ```

   See [Uninstalling](#uninstalling) for exactly what this removes.

## Uninstalling

Either double-click Dockling in Applications and click **Uninstall** (with a confirmation step first), or run:

```sh
~/.dockling/bin/DocklingAgent --uninstall
```

Both remove the same things:

- Dockling's own hook entries from `~/.claude/settings.json` — a clean removal, same guarantee as install: any other tool's hooks (or your own, for any event) are left exactly as found.
- The `launchd` registration, so it no longer starts at login.
- Every currently-running Dockling process — the dispatcher and any live session/subagent ducks.
- `~/.dockling` itself, including your saved config, per-project colors, and secret.

This can't be undone — a later reinstall starts from scratch (fresh per-project colors, default config) rather than restoring what was there before.

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
  "sound_effects_ready": false,
  "sound_effects_awaiting_input": false
}
```

- `subagent_ducks` (default `true`): when off, subagents don't get their own duck, and their activity has no effect on mama's icon either — it's as if they're invisible. The whole family-relaunch mechanism (see below) also never triggers, since it exists solely to keep babies grouped with mama.
- `sound_effects_ready` (default `true`): when off, the "ready for your next message" cue (on `Stop`) never plays.
- `sound_effects_awaiting_input` (default `true`): when off, the "waiting on you" cue (on `Notification`) never plays.

Both sound settings can also be toggled independently from the settings window.

Read once at process startup (dispatcher and every session child each load their own copy), so a change takes effect on the next restart, not live.

## Architecture

- **Dispatcher** (`DocklingAgent` run with no args): the one stable process, bound to the well-known hook port. Never appears in the Dock itself. On each new `session_id`, spawns a child process and hands it a dynamically allocated port.
- **Session child** (`DocklingAgent --session <id> --port <port> --color <color> --name <project>`): owns exactly one Dock icon (`NSApp.applicationIconImage`), launched through a synthesized per-project `.app` bundle so the Dock's hover tooltip shows the real project name. Exits when its session ends.
- **Auth**: every hook request (both real Claude Code hooks and the dispatcher's internal forwards to a child) must carry `?token=<secret>` matching `~/.dockling/secret`, or it's rejected.
- **Restart resilience**: the dispatcher persists its session table (pid/port/color per session) to `~/.dockling/sessions.json` and reconciles with it on startup — adopting still-running children instead of spawning duplicates, and dropping anything no longer alive. This is what makes the `launchd` `KeepAlive` restart-on-crash behavior safe. Baby ducks aren't in this registry (only mama tracks her own babies, in-memory) — a dispatcher restart while subagents are active can orphan their ducks, same trade-off the top-level registry exists to avoid.
- **Icon assets**: `--install` copies them to `~/.dockling/resources`, and every Dock icon loads from there rather than from inside the repo checkout. Loading straight out of the checkout (via SPM's `Bundle.module`) would trigger a macOS permission prompt on every single session/subagent spawn if the repo happens to live under Downloads, Desktop, or Documents — a real risk given how often people clone into Downloads by default.

## Known limitations

- Dev build only: no code signing, notarization, DMG, or Homebrew tap yet — that needs an Apple Developer account. Everything above runs from a local `swift build`.
- No telemetry of any kind (this is intentional, not a gap — see `DOCKLING_SPEC.md`).

## License

MIT — see [LICENSE](./LICENSE).
