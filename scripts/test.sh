#!/bin/sh
# Usage: scripts/test.sh [TestClass[/testMethod]]  — runs ClipbotCore unit tests, prints a summary.
set -u
cd "$(dirname "$0")/.."
xcodegen -q
LOG=build/test.log; mkdir -p build
if [ $# -gt 0 ]; then ONLY="-only-testing:ClipbotCoreTests/$1"; else ONLY=""; fi
xcodebuild test -scheme Clipbot -derivedDataPath build $ONLY > "$LOG" 2>&1
STATUS=$?
grep -E "error:|failed \(|: error|Executed [0-9]+ test" "$LOG" | sed 's|^.*/Tests/|Tests/|' | sort -u | tail -40
grep -E "\*\* TEST (SUCCEEDED|FAILED) \*\*" "$LOG" || echo "** BUILD FAILED (see $LOG) **"
exit $STATUS
