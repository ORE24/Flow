#!/usr/bin/env zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/local.flow.plist"
OLD_PLIST="$HOME/Library/LaunchAgents/local.study-task-overlay.plist"
mkdir -p "$HOME/Library/LaunchAgents"

if [[ -f "$OLD_PLIST" ]]; then
  launchctl unload "$OLD_PLIST" 2>/dev/null || true
  rm -f "$OLD_PLIST"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.flow</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>/Applications/Flow.app</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "$PLIST"
