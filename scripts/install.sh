#!/bin/sh
# Builds Clipbot (Release), installs it to /Applications and relaunches it.
#   scripts/install.sh          install as your user
#   scripts/install.sh --lock   install root-owned, so nothing running as you can replace the app
#                               (asks for your admin password; later installs then need --lock too)
set -eu
cd "$(dirname "$0")/.."
LOCK=0; [ "${1:-}" = "--lock" ] && LOCK=1
xcodegen -q
xcodebuild -scheme Clipbot -configuration Release -derivedDataPath build build > build/install.log 2>&1 \
  || { grep -E "error:" build/install.log | head -20; echo "build failed (build/install.log)"; exit 1; }
codesign --verify --strict build/Build/Products/Release/Clipbot.app
osascript -e 'tell application id "io.linus.clipbot" to quit' >/dev/null 2>&1 || true
pkill -x Clipbot 2>/dev/null || true
sleep 1
SUDO=""
if [ $LOCK -eq 1 ] || [ "$(stat -f %Su /Applications/Clipbot.app 2>/dev/null || echo none)" = "root" ]; then SUDO="sudo"; fi
$SUDO rm -rf /Applications/Clipbot.app
$SUDO cp -R build/Build/Products/Release/Clipbot.app /Applications/
[ -n "$SUDO" ] && sudo chown -R root:wheel /Applications/Clipbot.app && sudo chmod -R go-w /Applications/Clipbot.app
codesign --verify --strict /Applications/Clipbot.app
open /Applications/Clipbot.app
echo "Installed /Applications/Clipbot.app${SUDO:+ (root-owned)}"
