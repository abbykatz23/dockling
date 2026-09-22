#!/bin/sh
# Registers the dispatcher as a per-user launchd agent, so it starts at
# login and restarts if it ever crashes — without this, "run the dispatcher"
# means remembering to do it by hand every time. Run ./install/install.sh
# first (this expects a release build to already exist).
set -eu

# Points at install.sh's permanent copy, not the build output directly —
# critical if install.sh was run from a mounted DMG, since that build
# output path (/Volumes/Dockling/...) stops existing the moment the disk
# image is ejected, which would silently break auto-start at next login.
BINARY="$HOME/.dockling/bin/DocklingAgent"
LABEL="com.dockling.dispatcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.dockling/logs"

if [ ! -x "$BINARY" ]; then
  echo "error: $BINARY not found — run ./install/install.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# --dispatcher tells main.swift this is the real, headless, long-running
# dispatcher, as opposed to a plain double-click in Finder (which shows the
# first-run install UI instead) — both otherwise call the same binary with
# no other arguments. No PATH override needed: everything Dockling shells
# out to (xattr, pgrep, osascript, launchctl) is invoked by absolute path.
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BINARY</string>
        <string>--dispatcher</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/dispatcher.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/dispatcher.log</string>
</dict>
</plist>
EOF

UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true

# A private, unpredictable temp file rather than a fixed /tmp path: /tmp is
# world-writable, and a fixed filename there is a symlink-attack target —
# another local user could pre-create a symlink at that path pointing at any
# file we can write, which this script's redirect would then clobber.
ERROR_LOG=$(mktemp)
trap 'rm -f "$ERROR_LOG"' EXIT

# launchd can take a moment to fully release the label after bootout —
# bootstrapping immediately after occasionally fails with a transient I/O
# error. Retry rather than requiring the caller to re-run this by hand.
attempt=1
until launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>"$ERROR_LOG"; do
  if [ "$attempt" -ge 5 ]; then
    echo "error: launchctl bootstrap failed after $attempt attempts:" >&2
    cat "$ERROR_LOG" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.5
done

echo "Installed and started $LABEL — the dispatcher will now start automatically at login."
echo "Logs: $LOG_DIR/dispatcher.log"
echo "To stop permanently: launchctl bootout gui/$UID_NUM/$LABEL && rm $PLIST"
