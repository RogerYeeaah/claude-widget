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
rm -rf /Applications/ClaudeWidget.app
cp -R "$DERIVED" /Applications/ClaudeWidget.app
open /Applications/ClaudeWidget.app
sleep 3
pluginkit -e use -i com.local.ClaudeWidget.extension
echo "Done! Right-click desktop → Edit Widgets to add Claude."
