#!/bin/sh
# SessionStart command hook — the one event Dockling needs to run as a real
# shell command instead of Claude Code's own "http" hook POST, specifically
# to read $TMUX_PANE from the terminal's own environment (an http hook never
# touches the terminal's shell, so it can't see this). Forwards Claude Code's
# own JSON body unchanged, passing tmux_pane as a URL query param instead of
# merging it into the body — deliberately avoids needing jq (or any other
# JSON tool) just to run this one script. See DOCKLING_SPEC.md's tmux-bridge
# discussion (Phase 3) for why this mapping is needed.
set -eu

INPUT=$(cat)
TOKEN=$(cat "$HOME/.dockling/secret" 2>/dev/null || echo "")
# $TMUX_PANE is always of the form %<digits> (e.g. "%3"); percent-encode the
# one character that's special in a URL query rather than pulling in a full
# urlencode dependency for it.
PANE_ENCODED=$(printf '%s' "${TMUX_PANE:-}" | sed 's/%/%25/g')

curl -s -m 2 -X POST "http://127.0.0.1:8765/hook?token=${TOKEN}&tmux_pane=${PANE_ENCODED}" \
  -H 'Content-Type: application/json' \
  -d "$INPUT" > /dev/null || true

exit 0
