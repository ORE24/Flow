#!/usr/bin/env zsh
set -euo pipefail

PLISTS=(
  "$HOME/Library/LaunchAgents/local.flow.plist"
  "$HOME/Library/LaunchAgents/local.study-task-overlay.plist"
)

for plist in "${PLISTS[@]}"; do
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
  fi
done

echo "Flow login item removed"
