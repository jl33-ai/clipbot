#!/bin/sh
# Builds Dclip (Release), installs it to /Applications and relaunches it.
#   scripts/install.sh          install as your user
#   scripts/install.sh --lock   install root-owned, so nothing running as you can replace the app
#                               (asks for your admin password; later installs then need --lock too)
set -eu
cd "$(dirname "$0")/.."
LOCK=0; [ "${1:-}" = "--lock" ] && LOCK=1
xcodegen -q
xcodebuild -scheme Clipbot -configuration Release -derivedDataPath build build > build/install.log 2>&1 \
  || { grep -E "error:" build/install.log | head -20; echo "build failed (build/install.log)"; exit 1; }
codesign --verify --strict build/Build/Products/Release/Dclip.app
osascript -e 'tell application id "io.linus.clipbot" to quit' >/dev/null 2>&1 || true
pkill -x Dclip 2>/dev/null || true
pkill -x Clipbot 2>/dev/null || true # the app before it was renamed
sleep 1
SUDO=""
if [ $LOCK -eq 1 ] || [ "$(stat -f %Su /Applications/Dclip.app 2>/dev/null || echo none)" = "root" ]; then SUDO="sudo"; fi
$SUDO rm -rf /Applications/Dclip.app
$SUDO cp -R build/Build/Products/Release/Dclip.app /Applications/
[ -n "$SUDO" ] && sudo chown -R root:wheel /Applications/Dclip.app && sudo chmod -R go-w /Applications/Dclip.app
# Same bundle id, so the old Clipbot.app would be a second copy of this app: remove it.
if [ -d /Applications/Clipbot.app ]; then OLDSUDO=""; [ "$(stat -f %Su /Applications/Clipbot.app)" = "root" ] && OLDSUDO="sudo"; $OLDSUDO rm -rf /Applications/Clipbot.app; fi
codesign --verify --strict /Applications/Dclip.app
open /Applications/Dclip.app
echo "Installed /Applications/Dclip.app${SUDO:+ (root-owned)}"
