#!/bin/sh
# Registers the dispatcher as a per-user launchd agent, so it starts at
# login and restarts if it ever crashes — without this, "run the dispatcher"
# means remembering to do it by hand every time. Run ./install/install.sh
# first (this expects a release build to already exist).
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
BINARY="$REPO_ROOT/DocklingAgent/.build/release/DocklingAgent"
LABEL="com.dockling.dispatcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.dockling/logs"

if [ ! -x "$BINARY" ]; then
  echo "error: $BINARY not found — run ./install/install.sh first" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

# PATH is deliberately explicit and includes both Homebrew prefixes: launchd
# agents don't inherit your shell's PATH, and the reply-from-Dock feature
# shells out to `tmux`, which on most Macs is a Homebrew install.
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
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
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
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo "Installed and started $LABEL — the dispatcher will now start automatically at login."
echo "Logs: $LOG_DIR/dispatcher.log"
echo "To stop permanently: launchctl bootout gui/$UID_NUM/$LABEL && rm $PLIST"
