#!/bin/bash
# Runs one test scheme in isolation from any other run on this Mac.
#
#   scripts/run-tests.sh [Aletheia|AletheiaAcceptance|AletheiaUITests] [xcodebuild args...]
#
# - One run at a time: a lock folder (/private/tmp/aletheia-tests.lock) is taken
#   with mkdir, so a second run waits instead of fighting over the app and its
#   fixture folders. A lock left by a run that died is taken over.
# - Each run gets its own derived data, result bundle and acceptance ledger
#   under build/runs/<scheme>-<time>, so runs never read each other's output.
#   A ledger folder already set in TEST_RUNNER_ACCEPTANCE_LEDGER_DIR
#   (as CI sets it) is kept. DERIVED_DATA=<folder> reuses a build instead of a
#   fresh one (faster, but shared with whatever else uses that folder).
# - Per-test time limits: 60s by default, 120s for a test that asks for more.
#
# Extra arguments go to xcodebuild, e.g. -only-testing:AletheiaAcceptance/ChatTests.
# Exit status: xcodebuild's.

set -uo pipefail
cd "$(dirname "$0")/.."

SCHEME="${1:-AletheiaAcceptance}"
[ $# -gt 0 ] && shift
case "$SCHEME" in
    Aletheia|AletheiaAcceptance|AletheiaUITests) ;;
    *) sed -n '2,/^$/p' "$0"; exit 2 ;;
esac

LOCK=/private/tmp/aletheia-tests.lock
until mkdir "$LOCK" 2>/dev/null; do
    holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
        echo "Taking over the lock left by stopped run $holder."
        rm -rf "$LOCK"
        continue
    fi
    echo "Another test run (${holder:-starting}) holds $LOCK; waiting."
    sleep 5
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK"' EXIT INT TERM

RUN="build/runs/$SCHEME-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
if [ -z "${TEST_RUNNER_ACCEPTANCE_LEDGER_DIR:-}" ]; then
    # The tests run inside the sandboxed app, which can only write to its own container.
    export TEST_RUNNER_ACCEPTANCE_LEDGER_DIR="$HOME/Library/Containers/com.astrealabs.aletheia/Data/tmp/acceptance-ledger-$(basename "$RUN")"
fi
mkdir -p "$TEST_RUNNER_ACCEPTANCE_LEDGER_DIR"

[ -d Aletheia.xcodeproj ] || xcodegen generate >/dev/null

echo "Run folder: $RUN"
xcodebuild test \
    -project Aletheia.xcodeproj \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA:-$RUN/DerivedData}" \
    -resultBundlePath "$RUN/Results.xcresult" \
    -skipPackagePluginValidation \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    "$@" 2>&1 | tee "$RUN/xcodebuild.log" | /usr/bin/grep -E "error:|failed|passed|Executed|\*\* TEST"
status=${PIPESTATUS[0]}

if [ "$SCHEME" = AletheiaAcceptance ]; then
    cp "$TEST_RUNNER_ACCEPTANCE_LEDGER_DIR"/acceptance-ledger.* "$RUN"/ 2>/dev/null || true
fi
echo "Result bundle: $RUN/Results.xcresult (exit $status)"
exit "$status"
