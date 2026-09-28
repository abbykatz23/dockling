# Dockling

A live, per-session duck in your macOS Dock for Claude Code, showing what each session is doing in real time.

## What it does

- One Dock icon per active Claude Code session (not one aggregate icon), driven by Claude Code's [hook system](https://docs.claude.com/en/docs/claude-code/hooks).
- Each session's duck gets a random color from a 9-color pool, avoiding colors currently in use by other active sessions; that color is then remembered per project (see [Per-project colors](#per-project-colors)).
- Hovering a Dock icon shows the project name.
- The duck's pose changes in real time with what that session is doing — see the [Duck Key](#duck-key) below for exactly what each pose means and when it shows up.
- Sound effects: a short cue plays when a session becomes ready for your next message, and another when it's specifically waiting on you to answer something — each independently toggleable (see [Configuration](#configuration)).
- Each subagent a session spawns gets its own duck too — same color as its parent, 80% her size — that appears while the subagent's working and disappears shortly after it reports back. Capped at 3 baby ducks per session by default, so a big burst of subagents doesn't take over the Dock. See [Subagent ("baby") ducks](#subagent-baby-ducks). Both the ducks themselves and the cap can be turned off — see [Configuration](#configuration).

## Duck Key

| | Pose | When it shows |
|---|---|---|
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/idle.png" width="64" alt="Idle"> | **Idle** | A session just started, or a turn ended without calling any tools |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/bash.png" width="64" alt="Bash"> | **Running a shell command** | A Bash/shell tool call is in progress |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/edit.png" width="64" alt="Edit"> | **Editing a file** | A file-editing tool call is in progress |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/search.png" width="64" alt="Search"> | **Searching or reading** | A web search or codebase search/read tool call is in progress |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/other.png" width="64" alt="Other"> | **Using a tool** | Any other tool call — also shown right after you send a new message, standing in for "thinking," since there's no hook for when the model actually starts generating |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/awaiting-input.png" width="64" alt="Awaiting input"> | **Waiting on you** | Claude Code needs your input or permission to continue |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/error.png" width="64" alt="Error"> | **Error** | A tool call failed |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/eureka.png" width="64" alt="Eureka"> | **Task complete** | A turn that did real work (called at least one tool) finished successfully, or a todo-list-style milestone completed |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/committing-bride.png" width="64" alt="Committing (bride)"> <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/committing-groom.png" width="64" alt="Committing (groom)"> | **Committing** | Running `git commit` — bride or groom formalwear, picked randomly once per session/subagent process, not configurable |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/pulling.png" width="64" alt="Pulling"> | **Pulling** | Running `git pull` |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/pushing.png" width="64" alt="Pushing"> | **Pushing** | Running `git push` |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/testing.png" width="64" alt="Testing"> | **Running tests** | Running a test suite — `pytest`, `jest`, `npm test`, and similar |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/compressing.png" width="64" alt="Compressing"> | **Compressing or compacting** | Running `zip`/`tar`/`gzip`/etc. — also shown when Claude Code compacts its own context |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/sleepy.png" width="64" alt="Sleepy"> | **Idle 5+ minutes** | No activity for 5 minutes straight; any activity wakes the duck right back up |
| <img src="DocklingAgent/Sources/DocklingAgent/Resources/yellow/butt.png" width="64" alt="Farewell"> | **Session ending** | Shown for 1.5s right before the duck exits, as the session ends |

Shown here in yellow — the actual color is per-project, not per-pose (see [Per-project colors](#per-project-colors)). This same key is also shown in-app, in the settings window.

## Requirements

- macOS

## Setup

### Option A: download (no Terminal, no Swift toolchain)

1. Install via Homebrew:

   ```sh
   brew install --cask abbykatz23/dockling/dockling
   ```

   Or download the latest signed, notarized DMG from [Releases](https://github.com/abbykatz23/dockling/releases), open it, and drag Dockling to Applications.
2. Open Dockling from Applications (or Spotlight) and click **Install**. This wires Dockling into `~/.claude/settings.json` so *every* Claude Code session on your machine reports its state — not just sessions run from inside a checkout of this repo — and registers it to start automatically at login. A window opens right after with your settings (see [Configuration](#configuration)) and the [Duck Key](#duck-key). Opening Dockling again later reopens this same window, where you can also change settings, Update, Reinstall, or Uninstall.
3. Start or continue any Claude Code session. A duck appears in the Dock once the session's first hook fires (`SessionStart`, or the first tool call in some clients).

To uninstall, double-click Dockling in Applications again and click **Uninstall** — see [Uninstalling](#uninstalling).

### Option B: from source

Needs the Swift toolchain (Xcode Command Line Tools is enough — `xcode-select --install`). Not required for Option A — the DMG ships a prebuilt binary and needs nothing beyond macOS itself.

1. **Build and register the hooks.** Same clean-merge guarantee as above: your existing hooks (for any event, any tool) are left untouched, and re-running this is always safe.

   ```sh
   ./install/install.sh
   ```

   This also generates a per-install secret at `~/.dockling/secret`, required on every hook request so no other local process can spoof an event.

2. **Run the dispatcher.** This is the one long-lived background process — it gives each session its own Dock icon.

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

**Just dragging Dockling.app to the Trash also works**, even without opening it to click Uninstall first — it notices and uninstalls itself the same way, within about two minutes.

## Updating

Open Dockling (in Applications) and use the **Check for Updates** button in the settings window — no need to download a new DMG or drag anything to Applications by hand:

1. Click **Check for Updates**. If a newer release exists, the button changes to **Update to &lt;version&gt;**.
2. Click it again to download, verify, and install that release. Your ducks are already running the new version by the time this finishes.
3. You'll be offered **Relaunch Now** so Dockling.app itself picks up the new version too — **Later** is fine either way, since your ducks are already updated.

This checks `github.com/abbykatz23/dockling`'s latest release, verifies it's signed and notarized (the same check Gatekeeper itself would do) and signed by the same developer as the copy you already have installed, before installing it — never an arbitrary/unverified download. Not available for a from-source build (nothing to update *to* via this path — use `git pull` + rebuild instead).

**Reinstall vs. Update** — the settings window also has a **Reinstall** button, which does something different: it re-registers hooks using whatever's *already installed*, without checking for anything newer. Use it to repair a broken install (e.g. hooks got wiped by hand-editing `~/.claude/settings.json`) — Update won't help there, since as far as it's concerned nothing's out of date.

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
- When a subagent finishes (Claude Code's `SubagentStop` hook), her duck shows the eureka pose briefly, then disappears. If that signal is ever missed, a 10-minute fallback cleans her up anyway rather than leaving her frozen forever.
- The Dock doesn't let apps control their own icon order, so to keep a family together with mama rightmost, the whole family briefly flickers and regroups each time a new baby joins — the alternative was letting families get scattered apart by other sessions' activity in between. Several subagents joining in a quick burst still only causes one regroup, not one per subagent.

## Configuration

Create `~/.dockling/config.json` to change any of these (missing keys/file fall back to the defaults below — there's nothing to set up for the common case):

```json
{
  "subagent_ducks": false,
  "limit_subagent_ducks": false,
  "sound_effects_ready": false,
  "sound_effects_awaiting_input": false
}
```

- `subagent_ducks` (default `true`): when off, subagents don't get their own duck, and their activity has no effect on mama's icon either — it's as if they're invisible. The Dock-regrouping flicker (see [Subagent ("baby") ducks](#subagent-baby-ducks)) also never triggers, since it exists solely to keep babies grouped with mama.
- `limit_subagent_ducks` (default `true`): caps a session at 3 baby ducks at once. A session that fans out many subagents in a burst can otherwise spawn a baby duck per subagent with no ceiling, which crowds the Dock fast. Subagents beyond the cap simply don't get a duck — their actual work is unaffected. The cap itself (3) isn't configurable, only this on/off switch.
- `sound_effects_ready` (default `true`): when off, the "ready for your next message" cue (on `Stop`) never plays. Debounced by 5 seconds — a single turn that orchestrates several subagents can fire several genuine `Stop` events internally before the one final response you actually see, so only the last one in a burst plays a sound.
- `sound_effects_awaiting_input` (default `true`): when off, the "waiting on you" cue (on `Notification`) never plays.

All four of these can also be toggled from the settings window.

Changes need a restart to take effect, except `limit_subagent_ducks`, which applies immediately.

## Known limitations

- No official Claude Code plugin listing yet — Homebrew and the signed, notarized DMG on [Releases](https://github.com/abbykatz23/dockling/releases) are the two install paths today.
- No telemetry of any kind — this is intentional, not a gap.

## License

MIT — see [LICENSE](./LICENSE).
