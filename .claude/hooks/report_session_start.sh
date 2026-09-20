#!/bin/sh
# SessionStart command hook — the one event Dockling needs to run as a real
# shell command instead of Claude Code's own "http" hook POST, specifically
# to read $TMUX_PANE from the terminal's own environment (an http hook never
# touches the terminal's shell, so it can't see this). Enriches the same
# JSON Claude Code already gives every hook with tmux_pane, then forwards it
# to the existing dispatcher endpoint. See DOCKLING_SPEC.md's tmux-bridge
# discussion (Phase 3) for why this mapping is needed.
set -eu

INPUT=$(cat)
PAYLOAD=$(echo "$INPUT" | jq --arg pane "${TMUX_PANE:-}" '. + {tmux_pane: $pane}')
TOKEN=$(cat "$HOME/.dockling/secret" 2>/dev/null || echo "")

curl -s -m 2 -X POST "http://127.0.0.1:8765/hook?token=${TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" > /dev/null || true

exit 0
