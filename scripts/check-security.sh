#!/bin/sh
# Verifies the built app is locked down. Usage: scripts/check-security.sh [path/to/Dclip.app]
# Default: the Release build in build/. Exits non-zero on any failure.
set -u
APP="${1:-build/Build/Products/Release/Dclip.app}"
BIN="$APP/Contents/MacOS/Dclip"
CORE="$APP/Contents/Frameworks/ClipbotCore.framework/ClipbotCore"
FAIL=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAIL=1; }

[ -x "$BIN" ] || { echo "no app at $APP"; exit 2; }
echo "Checking $APP"

codesign --verify --strict --deep "$APP" 2>/dev/null && pass "signature valid" || fail "signature invalid"
codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' && pass "hardened runtime on" || fail "hardened runtime off"

ENTS=$(codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -convert json -o - - 2>/dev/null)
EXPECTED='{"com.apple.security.app-sandbox":true,"com.apple.security.files.user-selected.read-write":true}'
[ "$(echo "$ENTS" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(",",":")))')" = "$EXPECTED" ] \
  && pass "entitlements are exactly: sandbox + user-selected files" || fail "unexpected entitlements: $ENTS"

HELPER="$APP/Contents/XPCServices/ClipReader.xpc"
HELPER_BIN="$HELPER/Contents/MacOS/ClipReader"
if [ -x "$HELPER_BIN" ]; then
  pass "isolated clipboard reader embedded (ClipReader.xpc)"
  codesign -dv "$HELPER" 2>&1 | grep -q 'flags=.*runtime' && pass "reader: hardened runtime on" || fail "reader: hardened runtime off"
  HENTS=$(codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin),sort_keys=True,separators=(",",":")))')
  [ "$HENTS" = '{"com.apple.security.app-sandbox":true}' ] && pass "reader: entitlements are exactly: sandbox" || fail "reader: unexpected entitlements: $HENTS"
else
  fail "isolated clipboard reader missing: $HELPER_BIN"
fi

for lib in "$BIN" "$CORE" "$HELPER_BIN"; do
  name=$(basename "$lib")
  if otool -L "$lib" | grep -qiE 'CFNetwork|Network\.framework|libcurl|WebKit'; then fail "$name links a networking framework"; else pass "$name links no networking frameworks"; fi
  if nm -u "$lib" 2>/dev/null | grep -qE 'URLSession|NSURLConnection|nw_connection|nw_endpoint|_socket$|_connect$|CFSocket|CFStreamCreatePairWithSocket|_getaddrinfo'; then
    fail "$name references networking symbols"; else pass "$name references no networking symbols"; fi
done

PLIST="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" = "io.linus.clipbot" ] \
  && pass "bundle id io.linus.clipbot" || fail "unexpected bundle id"
DEBUG_APP="build/Build/Products/Debug/Dclip Debug.app"
for old in Clipbot Dclip; do if [ -d "build/Build/Products/Debug/$old.app" ]; then fail "stale Debug build shares the real app's identity: build/Build/Products/Debug/$old.app"; fi; done
if [ -d "$DEBUG_APP" ]; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEBUG_APP/Contents/Info.plist")" != "io.linus.clipbot" ] \
    && pass "Debug build has its own identity (can't open real data)" || fail "Debug build shares the real bundle id"
fi
OWNER=$(stat -f %Su "$APP")
[ "$OWNER" = "root" ] && pass "app bundle owned by root (can't be swapped without admin)" \
  || echo "  note app bundle owned by $OWNER — run 'scripts/install.sh --lock' to make it root-owned"
for key in CFBundleURLTypes CFBundleDocumentTypes NSServices NSAppleScriptEnabled OSAScriptingDefinition NSExtension; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 && fail "Info.plist exposes $key" || true
done
pass "no URL schemes, document types, services, scripting or extensions"

[ $FAIL -eq 0 ] && echo "All security checks passed." || echo "Security checks FAILED."
exit $FAIL
