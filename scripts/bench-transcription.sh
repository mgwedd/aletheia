#!/bin/bash
# Transcription model benchmark on a real recording (local, on-device only).
#
# Runs the Debug app's `--harness-bench` mode: transcribes the audio with each
# Whisper model through the app's own engine (Metal whisper.cpp in Debug), times
# each, and scores each against the first model (large-v3, the authoritative
# target) by word error rate. Prompts for the audio file when none is given.
#
# Usage:
#   scripts/bench-transcription.sh [AUDIO] [--models large-v3,medium.en,small.en]
#       [--start-min M] [--minutes N] [--out DIR] [--app PATH]
#     AUDIO        any file Core Audio reads (e.g. a session's call.caf/mic.caf;
#                  decrypt sealed recordings first). Prompted for if omitted.
#     --models     comma list, reference first (default large-v3,medium.en,small.en).
#     --start-min / --minutes  benchmark only a slice (whole file by default).
#     --out DIR    where transcripts + summary.txt land (default
#                  ~/Documents/aletheia-bench/<timestamp>, owner-only).
#     --app PATH   Aletheia.app to run (default: the Debug build, as harness.sh).
#
# Models not yet downloaded are fetched (after asking) from the pinned,
# checksum-verified source the app itself uses. Nothing else touches the
# network. Transcripts are PHI: they stay on this Mac in --out, mode 600.
# Ctrl-C stops early and keeps the models that finished.

set -uo pipefail
cd "$(dirname "$0")/.."

AUDIO=""; OUT=""; APP="${APP:-build/Build/Products/Debug/Aletheia.app}"
MODELS="large-v3,medium.en,small.en"; EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --models) MODELS="$2"; shift 2 ;;
        --start-min) EXTRA+=(--start-min "$2"); shift 2 ;;
        --minutes) EXTRA+=(--minutes "$2"); shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --app) APP="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        -*) sed -n '2,/^$/p' "$0"; exit 2 ;;
        *) AUDIO="$1"; shift ;;
    esac
done

BIN="$APP/Contents/MacOS/Aletheia"
[ -x "$BIN" ] || { echo "No app binary at $BIN (build the Debug config first, or pass --app)" >&2; exit 2; }

if [ -z "$AUDIO" ]; then
    read -e -r -p "Audio file to benchmark (drag it here): " AUDIO
    # Dragged paths arrive quoted or with backslash-escaped spaces.
    AUDIO="${AUDIO%"${AUDIO##*[![:space:]]}"}"; AUDIO="${AUDIO#\'}"; AUDIO="${AUDIO%\'}"
    AUDIO="${AUDIO#\"}"; AUDIO="${AUDIO%\"}"; AUDIO="${AUDIO//\\ / }"
fi
[ -f "$AUDIO" ] || { echo "Not a file: $AUDIO" >&2; exit 2; }

MODELS_DIR="$HOME/Library/Containers/com.aletheia.app/Data/Library/Application Support/Aletheia"
MISSING=()
for model in ${MODELS//,/ }; do
    [ -f "$MODELS_DIR/ggml-$model.bin" ] || MISSING+=("$model")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Not downloaded yet: ${MISSING[*]} (large-v3 ~3.1 GB, medium.en ~1.5 GB, small.en ~0.5 GB)."
    read -r -p "Download them now? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] && EXTRA+=(--harness-download)
fi

# The app is sandboxed: stage a clone of the audio (APFS clone, no extra disk)
# and its output inside its container, then move the results out.
WORK="$HOME/Library/Containers/com.aletheia.app/Data/tmp/bench.$$"
mkdir -p "$WORK/out" && chmod 700 "$WORK"
STAGED="$WORK/audio.${AUDIO##*.}"
cp -c "$AUDIO" "$STAGED" 2>/dev/null || cp "$AUDIO" "$STAGED"
[ -n "$OUT" ] || OUT="$HOME/Documents/aletheia-bench/$(date +%Y-%m-%d_%H%M%S)"

APP_PID=""
finish() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    mkdir -p "$OUT" && chmod 700 "$OUT"
    mv "$WORK/out/"* "$OUT/" 2>/dev/null
    rm -rf "$WORK"
    echo
    echo "Results: $OUT"
}
trap 'finish; exit 130' INT TERM

"$BIN" --harness-bench "$STAGED" --out "$WORK/out" --models "$MODELS" ${EXTRA[@]+"${EXTRA[@]}"} &
APP_PID=$!
wait "$APP_PID"; STATUS=$?
APP_PID=""
finish
exit "$STATUS"
