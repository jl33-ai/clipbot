#!/bin/sh
# Usage: scripts/test.sh [TestClass[/testMethod]] — runs ClipbotCore unit tests.
# Pass/fail comes from xcodebuild's exit code; on failure the compiler errors, failing
# assertions and log tail are printed.
set -u
cd "$(dirname "$0")/.."
xcodegen -q
LOG=build/test.log; mkdir -p build
xcodebuild test -scheme Clipbot -derivedDataPath build ${1:+-only-testing:ClipbotCoreTests/$1} > "$LOG" 2>&1
STATUS=$?
grep -E 'Executed [0-9]+ tests' "$LOG" | tail -1
if [ $STATUS -ne 0 ]; then
  grep -E '\.swift:[0-9]+(:[0-9]+)?: error:' "$LOG" | sed 's|^.*/clipbot/||' | sort -u | head -40
  echo "--- last lines of $LOG ---"; tail -15 "$LOG"
  echo "** TESTS FAILED **"
else
  echo "** TESTS PASSED **"
fi
exit $STATUS
