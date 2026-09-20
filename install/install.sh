#!/bin/sh
# Registers Dockling's hooks into the user-level ~/.claude/settings.json, so
# every Claude Code session on this machine reports to the dispatcher — not
# just sessions run inside this repo. Safe to re-run: merges by event,
# replacing only the hook group it previously added (matched by a signature,
# not position), and never touches any other hooks you already have
# configured for the same or other events. See DOCKLING_SPEC.md's Security &
# Privacy section ("Hook installation ... must be a clean merge").
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

for cmd in jq curl openssl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: '$cmd' is required but not found on PATH" >&2
    exit 1
  }
done

DOCKLING_DIR="$HOME/.dockling"
mkdir -p "$DOCKLING_DIR/hooks"
chmod 700 "$DOCKLING_DIR"

# Per-install shared secret: every hook request must carry this (as
# ?token=...) or the dispatcher rejects it, so no other local process can
# spoof a hook event or trigger a fake reply popover. Also self-bootstrapped
# by the app itself (Secret.swift) if this script is never run — generating
# it here too just means the very first hook delivery already works.
SECRET_FILE="$DOCKLING_DIR/secret"
if [ ! -s "$SECRET_FILE" ]; then
  openssl rand -hex 32 > "$SECRET_FILE"
  chmod 600 "$SECRET_FILE"
  echo "Generated a new Dockling secret at $SECRET_FILE"
fi
TOKEN=$(cat "$SECRET_FILE")

# Installed to a stable path outside any one project, since these hooks now
# apply globally rather than just to sessions run inside this repo.
cp "$REPO_ROOT/.claude/hooks/report_session_start.sh" "$DOCKLING_DIR/hooks/report_session_start.sh"
chmod +x "$DOCKLING_DIR/hooks/report_session_start.sh"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP=$(mktemp)
cp "$SETTINGS" "$TMP"

# Removes any hook group this installer previously added for $event (matched
# by $marker against every hook's command/url in that group — not by array
# position), then appends $new_group. Anything else already configured for
# this event, or any other event, is left completely untouched.
merge_group() {
  event="$1"
  marker="$2"
  new_group="$3"
  jq \
    --arg event "$event" \
    --arg marker "$marker" \
    --argjson newGroup "$new_group" \
    '.hooks[$event] = ((.hooks[$event] // [])
       | map(select((.hooks // []) | any((.command? // .url? // "") | test($marker)) | not))
     ) + [$newGroup]' \
    "$TMP" > "$TMP.next"
  mv "$TMP.next" "$TMP"
}

session_start_group=$(jq -n --arg cmd "$DOCKLING_DIR/hooks/report_session_start.sh" \
  '{hooks: [{type: "command", command: $cmd}]}')
merge_group "SessionStart" "report_session_start\\.sh" "$session_start_group"

hook_url="http://127.0.0.1:8765/hook?token=$TOKEN"
http_group=$(jq -n --arg url "$hook_url" '{hooks: [{type: "http", url: $url}]}')
for event in PreToolUse PostToolUseFailure TaskCompleted Notification Stop StopFailure SessionEnd; do
  merge_group "$event" "127\\.0\\.0\\.1:8765/hook" "$http_group"
done

mv "$TMP" "$SETTINGS"

echo "Dockling hooks installed into $SETTINGS — this now applies to every Claude Code session on this machine, not just this repo."
echo
echo "Next: build and run the dispatcher (keep it running in the background):"
echo "  cd \"$REPO_ROOT/DocklingAgent\" && swift build && .build/debug/DocklingAgent &"
