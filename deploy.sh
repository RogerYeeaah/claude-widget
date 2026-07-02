#!/bin/bash
set -e

cd "$(dirname "$0")"

# 1. Ensure xcodegen is installed
if ! command -v xcodegen &>/dev/null; then
  echo "Installing xcodegen..."
  brew install xcodegen
fi

# 2. Generate Xcode project
echo "Generating Xcode project..."
xcodegen generate --quiet

# 3. Build Release
echo "Building..."
if ! xcodebuild -scheme ClaudeWidget -configuration Release -quiet 2>/dev/null; then
  echo ""
  echo "Build failed. If this is your first time, open Xcode and sign in with your Apple ID:"
  echo "  Xcode → Settings → Accounts → Add Apple ID"
  echo "Then run this script again."
  open ClaudeWidget.xcodeproj
  exit 1
fi

# 4. Find built app
DERIVED=$(find ~/Library/Developer/Xcode/DerivedData -name "ClaudeWidget.app" -path "*/Release/*" 2>/dev/null | head -1)
if [ -z "$DERIVED" ]; then
  echo "Error: Release build not found."
  exit 1
fi

# 5. Install + enable
echo "Installing to /Applications..."
pkill -x ClaudeWidget || true
sleep 1
rm -rf /Applications/ClaudeWidget.app
cp -R "$DERIVED" /Applications/ClaudeWidget.app
open /Applications/ClaudeWidget.app
sleep 3
pluginkit -e use -i com.local.ClaudeWidget.extension
echo "Done! Right-click desktop → Edit Widgets to add Claude."

# 6. Install cache refresh hook + save repo path
echo "Installing usage cache refresh hook..."
echo "$(cd "$(dirname "$0")" && pwd)" > "$HOME/.claude/widget-repo-path"
SCRIPT_SRC="$(dirname "$0")/refresh-usage-cache.sh"
SCRIPT_DST="$HOME/.claude/refresh-usage-cache.sh"

cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

# Merge Stop hook into ~/.claude/settings.json without clobbering existing config
python3 - <<'PYEOF'
import json, os, sys

settings_path = os.path.expanduser("~/.claude/settings.json")
hook_cmd = "bash ~/.claude/refresh-usage-cache.sh"

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

hooks = settings.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

# Check if hook already registered
already = any(
    h.get("command") == hook_cmd
    for group in stop_hooks
    for h in group.get("hooks", [])
)
if already:
    print("  Hook already registered, skipping.")
    sys.exit(0)

stop_hooks.append({"hooks": [{"type": "command", "command": hook_cmd}]})

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
print("  Hook registered in ~/.claude/settings.json")
PYEOF
