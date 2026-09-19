# Dockling — Project Spec

2026-09-19 · @Someone

## Overview

A character-driven, always-live status indicator for Claude Code sessions, shown as the app's Dock icon on macOS (v1). Each running Claude Code session gets its own animated character in the Dock, whose pose/state changes in real time based on what that session is doing (idle, running a tool, awaiting input, etc.), driven by Claude Code's hook system.

The entire experience lives on-device: no hosted website, no accounts, no server. "Sharing this with the public" means distributing the local app itself (same model as Claude Pet, Masko Code, Claude Status Bar), not a hosted product.

**Why this is differentiated:** prior art in this space (Claude Status Bar, Code Light AI, Claude Code Notify) all use the menu bar or system tray with simple dots/icons, none use a character, and none use the Dock. Dock icon live-updating itself is a well-established macOS pattern (Activity Monitor's live CPU/network/disk graphs, Docker Desktop's animated whale, Xcode's build-progress ring), and multiple simultaneous Dock icons for one logical app is also proven (RStudio, Orion browser, the third-party tool Parall), so the mechanism is de-risked, but the specific combination of character plus Dock plus Claude Code appears to be open.

## State design

**Tool-state granularity:** bucketed, not fully per-tool and not a single generic state. v1 buckets: bash/shell commands, file edits, search (web or codebase), and a catch-all "other tool" bucket — each gets its own distinct pose, plus separate states for idle, awaiting input/permission, and error.

**Multi-session handling:** one Dock icon per active Claude Code session, not an aggregated single icon. This is confirmed technically feasible — macOS allows multiple simultaneous Dock icons for one logical app when each is a separate process (precedent: RStudio's per-project icons, Orion's per-profile icons, the third-party tool Parall). Each session spawns its own lightweight process instance so its icon can update independently.

- Icon disappears automatically when its session ends (quit/close), mirroring RStudio's behavior when a project window closes.
- **Session labeling — decided:** the character itself is the primary visual identifier. Hovering a Dock icon shows the project name/path, extending macOS's existing Dock hover-label mechanism. A small badge overlay is added to the sprite only when a character collision occurs (see character-pool exhaustion below) — the normal case stays clean, the badge is purely a disambiguation fallback.

**Per-project character assignment:** each VS Code / project workspace gets a distinct character. Default is random assignment from the pool of characters not currently in use by another active session; the user can also explicitly pin a character to a project.

**Character assignment — decided:**

1. Default assignment is random per project, then persisted locally so it stays stable across future runs unless overridden.
2. Users pin a specific character to a project via local config (CLI flag or config file edit; a native settings UI is a possible later refinement) — no hosted website or account involved, consistent with the on-device model described in the Overview.
3. Storage: local agent config holds the default/persisted assignment; a project-local dotfile can override it if present (lets teams check in a fixed character for collaborators).
4. Fallback when concurrent sessions exceed the character pool size — decided: duplicates are allowed; assignment reuses characters round-robin/random, and the collision badge (see Multi-session handling above) is the sole disambiguation mechanism. No procedural sprite variation or dynamic pool expansion in v1.

## Local agent architecture

**Tech stack:** native Swift/AppKit. No hosted website means no need for Electron/Tauri's cross-platform or web-rendering strengths — a small, tightly OS-integrated Mac utility is the better fit, and it matches the precedent set by Claude Status Bar (native, signed and notarized).

**Responsibilities:**

1. **Hook receiver** — listens for Claude Code hook events (PreToolUse, Notification, Stop, etc.).
2. **Per-session process spawning** — each active Claude Code session gets its own lightweight process instance so it can own a distinct Dock icon (see State design).
3. **Dock icon updater** — swaps/redraws each session's Dock icon based on its current state bucket.
4. **Reply mechanism** — replaces the earlier browser-based idea entirely. When a session enters "awaiting input," clicking its Dock icon opens a small native popover (in the style of Masko Code's speech-bubble UI) showing the question and a text field, right on top of the Dock. Submitting runs through a **tmux bridge**: the terminal running `claude` is wrapped in a tmux session, and the popover's submission is delivered via `tmux send-keys`.

**Known scope limit:** the tmux bridge only reaches a real shell process. It works for the CLI run in any plain terminal (including VS Code's *integrated* terminal), but not the dedicated Claude Code VS Code extension panel (a webview, not a tmux-reachable pane) — that would need its own, separate integration and is out of scope for v1.

## Character & asset system

**Format:** Shimeji-ee / Shijima-Qt sprite packs — the same format Claude Pet uses. This gives access to an existing community-sized ecosystem of character packs rather than needing bespoke art from scratch.

**Static vs. animation:** full animation. Technically no harder than static (the Dock icon is just an image being swapped/redrawn either way — same mechanism Activity Monitor uses for its live graphs), and baseline animations (idle, walking, sitting, etc.) come largely for free from a compatible pack.

**State-specific sprites:** generic packs don't include Claude-specific states (working, awaiting-input, error). Adopt Claude Pet's existing custom sprite-index convention (indices 38–50) for these rather than inventing a new scheme — keeps any pack already extended for Claude Pet compatible with Dockling too. Packs that don't define these fall back to a static first frame, matching Claude Pet's own fallback behavior.

**Art production:** adapt existing open sprite packs rather than commissioning original art or hand-drawing. Per-project character pool (see State design) draws from these adapted packs.

**Per-tool-bucket sprites:** bash/edit/search/other buckets (see State design) each need a distinct pose within the "working" custom-index range.

**Default character:** a duck, drawn with Nano Banana.

![Dockling default duck character](./dockling-duck-icon.png)

**Icon format requirements:**

- Static app icon (Finder / Applications / installer): `.icns`, multi-resolution (16×16 up to 1024×1024, 1x/2x). The duck's rounded-square teal-bezel style matches this role well as-is — it mirrors macOS's own icon convention since Big Sur.
- Live per-state Dock tile art (set at runtime via `NSDockTile`): plain PNG with alpha transparency, no `.icns` needed. Provide at 128×128 and 256×256 (Retina), 512×512 optional. Character alone on a transparent background, not the rounded-square bezel — macOS doesn't apply that automatically to a custom Dock tile, so baking it into every pose risks a doubled border. Keep canvas size and the character's anchor point consistent across all poses/frames to avoid visual jumping when the icon swaps state.

**Reference files (local):** saved at `~/Downloads/dockling` (app-icon version, background included) and `~/Downloads/dockling_transparent` (Dock-tile version, transparent background).

## Security & privacy

Everything is on-device (no hosted server), which removes most of what would otherwise be a concern. What's left:

- **Local channel auth:** hooks need a way to notify the running app (localhost HTTP endpoint, Unix socket, or a watched file). Whichever is chosen, it requires a per-install shared secret so no other local process can spoof hook events or trigger a fake reply popover.
- **Session attribution:** replies are injected via tmux into a specific pane, so session-ID tracking has to be reliable — a misrouted reply (e.g. approving a permission prompt) could land in the wrong project's terminal, which is a correctness bug with real consequences, not just an annoyance.
- **tmux's existing boundary:** its control socket is already scoped to the current OS user by file permissions, so this doesn't introduce new cross-user risk.
- **Hook installation:** auto-registering into `~/.claude/settings.json` must be a clean merge that never clobbers the user's existing hooks (established pattern, per Claude Status Bar / Code Island).
- **Distribution trust:** Developer ID signing + notarization, so Gatekeeper doesn't block or scare off installs.

**Data handling decisions:**

- Telemetry: opt-in only, anonymous (crash reports, feature usage) — never on by default.
- Hook payload content (commands, questions): fully ephemeral, kept in-memory only for current state, never written to disk.

## Distribution & packaging

**Name:** Dockling.

**Platform scope:** macOS-first (v1), native Swift/AppKit — relies on Dock APIs that are Mac-only. Windows/Linux equivalents (system tray) are a possible future add-on, not v1 scope.

**Install method:** GitHub Releases with a signed and notarized DMG (zero-gatekeeping launch path, same as Claude Status Bar / Code Light AI), plus a personal Homebrew tap (`brew install --cask dockling/tap/dockling` or similar) for a one-line install. An official Claude Code plugin listing (self-install from within Claude Code) is a fast-follow, not a v1 requirement.

**Open source:** yes. Fits naturally with the GitHub-based distribution above — releases as tags, tap synced from the same repo (or a companion repo).

## Rollout plan

**Phase 0 — smallest end-to-end demo:**

- Single Claude Code session only (no multi-session yet)
- Local agent as a minimal background process: hook receiver + Dock icon updater, one `NSDockTile`
- Static PNGs (duck) per state bucket: idle, bash, edit, search, other, awaiting-input, error
- No reply injection, no character pool, no telemetry, no installer — dev build only, run from Xcode
- Goal: prove the core loop (hook fires → Dock icon changes) actually works end to end

**Phase 1 — multi-session:**

- Per-session process spawning so each active session gets its own Dock icon
- Auto-remove icon on session quit/close

**Phase 2 — character system:**

- Random-by-default assignment from the character pool, not already in use by another active session
- Per-project pinning (local agent config, with project-local dotfile override)
- Swap static PNGs for full animation via adapted Shimeji-ee / Shijima-Qt packs

**Phase 3 — reply from the Dock:**

- Native popover on click during "awaiting input," showing the question + text field
- tmux bridge: wrap the terminal session, deliver replies via `tmux send-keys`
- Session-ID routing hardened so replies can't land in the wrong project's terminal

**Phase 4 — public launch polish:**

- Clean-merge hook installation into `~/.claude/settings.json` (never clobber existing hooks)
- Developer ID signing + notarization
- Distribution: GitHub Releases (signed DMG) + personal Homebrew tap
- Opt-in anonymous telemetry (crashes, feature usage)
- Open source repo cleanup: README, install instructions, license

**Explicitly out of scope (not v1, not near-term):**

- Claude Desktop / claude.ai chat support (no equivalent hook system)
- The dedicated Claude Code VS Code extension panel (not tmux-reachable; would need its own bridge)
- Windows/Linux system-tray equivalents
- Any hosted website or account system
