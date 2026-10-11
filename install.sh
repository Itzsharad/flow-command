#!/bin/bash
# Flow Command installer — downloads the latest version into /Applications and opens it.
# Usage:  curl -fsSL https://raw.githubusercontent.com/Itzsharad/flow-command/main/install.sh | bash
set -e
URL="https://github.com/Itzsharad/flow-command/releases/download/latest/FlowCommand.dmg"
TMP="$(mktemp -d)"
echo "→ Downloading Flow Command…"
curl -fL --progress-bar "$URL" -o "$TMP/FlowCommand.dmg"
echo "→ Installing…"
osascript -e 'quit app "FlowCommand"' >/dev/null 2>&1 || true
pkill -x FlowCommand >/dev/null 2>&1 || true
sleep 1
MNT="$(hdiutil attach -nobrowse -readonly "$TMP/FlowCommand.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
rm -rf "/Applications/FlowCommand.app"
cp -R "$MNT/FlowCommand.app" /Applications/
hdiutil detach "$MNT" -quiet || true
rm -rf "$TMP"
xattr -dr com.apple.quarantine /Applications/FlowCommand.app 2>/dev/null || true
echo "✓ Installed. Opening Flow Command…"
echo "  Look for the microphone icon at the top-right of your screen."
open /Applications/FlowCommand.app --args --welcome
