#!/bin/sh
# Builds Clipbot (Release) and installs it to /Applications, relaunching it.
set -eu
cd "$(dirname "$0")/.."
xcodegen -q
xcodebuild -scheme Clipbot -configuration Release -derivedDataPath build build > build/install.log 2>&1 \
  || { grep -E "error:" build/install.log | head -20; echo "build failed (build/install.log)"; exit 1; }
osascript -e 'tell application id "io.linus.clipbot" to quit' >/dev/null 2>&1 || true
pkill -x Clipbot 2>/dev/null || true
sleep 1
rm -rf /Applications/Clipbot.app
cp -R build/Build/Products/Release/Clipbot.app /Applications/
codesign --verify --strict /Applications/Clipbot.app
open /Applications/Clipbot.app
echo "Installed /Applications/Clipbot.app"
