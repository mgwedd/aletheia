#!/bin/bash
# Call-audio recording + transcription harness (local, on-device only).
#
# Generates a synthetic far-end fixture with `say`, launches the DEBUG app with
# `--harness-record`, plays the fixture with `afplay` as the far end while the app
# records mic + call audio, then checks the recordings and prints PASS/FAIL.
#
# Usage:
#   scripts/harness.sh [--mode auto|live] [--transcribe] [--out DIR] [--app PATH]
#     --mode auto   (default) nobody talks; the mic should stay near-silent.
#     --mode live   you read a displayed script aloud while the far end plays.
#     --transcribe  also run on-device Whisper (only if the model is already
#                   downloaded; never downloads) and report call-track WER plus
#                   how many fixture words leaked into the mic transcript.
#     --out DIR     where recordings/result.json land (default: a fresh dir in the app's
#                   sandbox container tmp; the sandboxed app can't write elsewhere).
#     --app PATH    Aletheia.app to run (or $APP; default: the Debug build at
#                   build/Build/Products/Debug/Aletheia.app, as built with
#                   `xcodegen generate && xcodebuild build -scheme Aletheia
#                   -configuration Debug -derivedDataPath build`).
#
# Requirements: the app being run needs the Screen & System Audio Recording and
# Microphone grants. An ad-hoc signed Debug build loses the Screen Recording grant
# every time it is rebuilt, so re-grant after each build. Without a grant the app
# fails fast (it never waits on a system dialog) and this script reports FAIL.
# Speaker output must be the audio route macOS captures; with speakers (not
# headphones) the far end will also bleed into the mic, which the leakage line shows.
#
# Output stays on this Mac: nothing here touches the network. Fixture text is synthetic.
# Exit status: 0 if every check passed, 1 otherwise.

set -uo pipefail
cd "$(dirname "$0")/.."

WER_THRESHOLD=0.25      # max call-track word error rate (with --transcribe)
DURATION_TOLERANCE=2    # seconds the call track may differ from the requested length
MIN_MIC_FRACTION=0.5    # mic track must be at least this fraction of the requested length

MODE=auto; TRANSCRIBE=0; OUT=""; APP="${APP:-build/Build/Products/Debug/Aletheia.app}"
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE="$2"; shift 2 ;;
        --transcribe) TRANSCRIBE=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        *) sed -n '2,/^$/p' "$0"; exit 2 ;;
    esac
done
[ "$MODE" = auto ] || [ "$MODE" = live ] || { echo "--mode must be auto or live" >&2; exit 2; }
BIN="$APP/Contents/MacOS/Aletheia"
[ -x "$BIN" ] || { echo "No app binary at $BIN (build the Debug config first, or pass --app)" >&2; exit 2; }

# The Debug app is sandboxed: it can only write inside its own container, so the
# fixture reference text and the output dir both live there.
WORK="$HOME/Library/Containers/com.astrealabs.aletheia/Data/tmp/harness.$$"
mkdir -p "$WORK"
[ -n "$OUT" ] || OUT="$WORK/out"
mkdir -p "$OUT"
cat > "$WORK/reference.txt" <<'EOF'
The quick brown fox jumps over the lazy dog near the river bank.
Today the weather is mild, and the market opens at nine in the morning.
Please remember to bring your blue notebook and two sharp pencils.
We will meet again next Thursday afternoon to review the garden plans.
EOF
say -o "$WORK/far.aiff" -f "$WORK/reference.txt"
FAR_SECONDS="$(afinfo "$WORK/far.aiff" | awk '/estimated duration/ {print int($3) + 1}')"
SECONDS_REQ=$((FAR_SECONDS + 4))

if [ "$MODE" = live ]; then
    echo "LIVE mode: when the far-end audio starts, read this aloud (near end):"
    echo "  \"I am speaking from my side of the call while the other voice plays.\""
    echo "  \"This sentence is only here so the microphone track has speech in it.\""
    echo
fi

ARGS=(--harness-record "$SECONDS_REQ" --out "$OUT" --harness-reference "$WORK/reference.txt")
[ "$TRANSCRIBE" = 1 ] && ARGS+=(--harness-transcribe)
"$BIN" "${ARGS[@]}" &
APP_PID=$!

# The app drops recording.started once both captures are running (or exits early on failure).
for _ in $(seq 1 300); do
    [ -e "$OUT/recording.started" ] && break
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 0.1
done
[ -e "$OUT/recording.started" ] && { sleep 1; afplay "$WORK/far.aiff"; }
wait "$APP_PID"; APP_STATUS=$?

FAIL=0
check() { # name, ok(0/1), detail
    if [ "$2" = 0 ]; then printf 'PASS  %-34s %s\n' "$1" "$3"; else printf 'FAIL  %-34s %s\n' "$1" "$3"; FAIL=1; fi
}
get() { plutil -extract "$1" raw -o - "$OUT/result.json" 2>/dev/null; }
# awk comparison helper: prints 0 when the awk expression is true.
cmp() { awk "BEGIN { exit !($1) }"; echo $?; }

echo
echo "Harness results ($OUT)"
check "app exit status" "$APP_STATUS" "status $APP_STATUS $(get error)"
[ -f "$OUT/result.json" ] || { check "result.json written" 1 "missing"; exit 1; }

CALL_DUR="$(get tracks.call.durationSeconds)"; MIC_DUR="$(get tracks.mic.durationSeconds)"
BUFFERS="$(get tracks.call.buffersReceived)"; SILENT="$(get tracks.call.silent)"
check "call track exists" "$([ -n "$CALL_DUR" ] && echo 0 || echo 1)" "$(get tracks.call.bytes) bytes"
check "call duration ~ requested" "$(cmp "${CALL_DUR:-0} > 0 && ${CALL_DUR:-0} - $SECONDS_REQ < $DURATION_TOLERANCE && $SECONDS_REQ - ${CALL_DUR:-0} < $DURATION_TOLERANCE")" "${CALL_DUR:-none}s of ${SECONDS_REQ}s"
check "call track non-silent" "$([ "$SILENT" = false ] && echo 0 || echo 1)" "peak $(get tracks.call.peak) rms $(get tracks.call.rms)"
check "mic track plausible duration" "$(cmp "${MIC_DUR:-0} >= $SECONDS_REQ * $MIN_MIC_FRACTION")" "${MIC_DUR:-none}s"
check "call buffers received > 0" "$(cmp "${BUFFERS:-0} > 0")" "${BUFFERS:-none}"
check "no stream error" "$([ -z "$(get tracks.call.error)" ] && [ "$(get tracks.call.streamDisrupted)" != true ] && echo 0 || echo 1)" "$(get tracks.call.error)"

if [ "$TRANSCRIBE" = 1 ]; then
    TX="$(get transcription)"
    if [ "$TX" = "model missing" ]; then
        check "transcription" 1 "Whisper model not downloaded (download it in Settings first)"
    else
        WER="$(get transcription.callWER)"
        check "call WER <= $WER_THRESHOLD" "$(cmp "${WER:-1} <= $WER_THRESHOLD")" "WER ${WER:-none}"
        echo "INFO  mic leakage: $(get transcription.micLeakedReferenceWords) of $(get transcription.referenceDistinctWords) distinct fixture words appear in the mic transcript"
    fi
fi

echo
[ "$FAIL" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$FAIL"
