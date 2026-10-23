#!/bin/bash
# Local LLM evaluation on one session (on-device only).
#
# Runs the Debug app's `--harness-eval` mode: through the app's own
# AssistantService + built-in engine it writes the session note, builds the
# session digest and answers one session-chat question, then prints each output
# with its coverage (the engine's prompt token count vs the estimate, whether the
# truncation tripwire fired, the coverage label), timings (prefill/decode
# tok/s, wall time) and and the model used.
#
# Usage:
#   scripts/eval-llm.sh [--session DIR | --transcript FILE] [--question TEXT]
#       [--model NAME] [--budget TOKENS] [--out DIR] [--app PATH]
#     --session DIR      a session folder holding a plain-text transcript.txt
#                        (decrypt first if the folder is encrypted).
#     --transcript FILE  a transcript text file ([MM:SS] Speaker: text lines).
#     --question TEXT    the chat question (a default is used if omitted).
#     --model NAME       model name (default: the app's configured model).
#     --budget TOKENS    override this Mac's context budget, to exercise the
#                        doesn't-fit path with a shorter transcript.
#     --out DIR          also write report.txt and report.json there (owner-only).
#                        Refused if inside this repository.
#     --app PATH         Aletheia.app to run (default: the Debug build).
#
# PRIVACY: the transcript is PHI. Output goes only to the terminal or to an
# --out directory outside the repo (refused otherwise); nothing here touches
# the network. Never commit a report.
# Use synthetic transcripts for anything you share.

set -uo pipefail
CWD="$PWD"   # user-supplied paths are relative to where they ran this, not the repo
cd "$(dirname "$0")/.."
REPO="$(pwd -P)"

SESSION=""; TRANSCRIPT=""; OUT=""; APP="${APP:-build/Build/Products/Debug/Aletheia.app}"; EXTRA=()
while [ $# -gt 0 ]; do
    case "$1" in
        --session) SESSION="$2"; shift 2 ;;
        --transcript) TRANSCRIPT="$2"; shift 2 ;;
        --question) EXTRA+=(--question "$2"); shift 2 ;;
        --model) EXTRA+=(--model "$2"); shift 2 ;;
        --budget) EXTRA+=(--budget "$2"); shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --app) APP="$2"; APP_FROM_USER=1; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0"; exit 0 ;;
        *) sed -n '2,/^$/p' "$0"; exit 2 ;;
    esac
done

abs() { case "$1" in /*|"") printf '%s' "$1" ;; *) printf '%s' "$CWD/$1" ;; esac; }
SESSION="$(abs "$SESSION")"; TRANSCRIPT="$(abs "$TRANSCRIPT")"; OUT="$(abs "$OUT")"
case "$APP" in /*) ;; *) [ "${APP_FROM_USER:-}" = 1 ] && APP="$CWD/$APP" ;; esac

[ -z "$TRANSCRIPT" ] && [ -n "$SESSION" ] && TRANSCRIPT="$SESSION/transcript.txt"
[ -f "$TRANSCRIPT" ] || { echo "Give --session DIR (with transcript.txt) or --transcript FILE" >&2; exit 2; }

# Checked before anything is staged or run.
if [ -n "$OUT" ]; then
    mkdir -p "$OUT" || exit 2
    OUT="$(cd "$OUT" && pwd -P)"
    # APFS is case-insensitive by default, so compare lowercased.
    lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
    case "$(lc "$OUT")/" in
        "$(lc "$REPO")"/*) echo "Refusing --out inside the repo ($OUT): reports contain PHI." >&2; rmdir "$OUT" 2>/dev/null; exit 2 ;;
    esac
fi

BIN="$APP/Contents/MacOS/Aletheia"
[ -x "$BIN" ] || { echo "No app binary at $BIN (build the Debug config first, or pass --app)" >&2; exit 2; }

# The app is sandboxed: stage the transcript and its output in its container.
STAGE="$HOME/Library/Containers/com.aletheia.app/Data/tmp"
# Leftovers from runs that were killed; a run still going keeps its own.
for dir in "$STAGE"/eval.*; do
    [ -d "$dir" ] || continue
    kill -0 "${dir##*.}" 2>/dev/null || rm -rf "$dir"
done
WORK="$STAGE/eval.$$"

APP_PID=""
finish() {
    [ -n "${DONE:-}" ] && return; DONE=1
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    if [ -n "$OUT" ]; then
        chmod 700 "$OUT"
        mv "$WORK/out/"* "$OUT/" 2>/dev/null && chmod 600 "$OUT"/report.* && echo "Report: $OUT"
    fi
    rm -rf "$WORK"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -p "$WORK/out" && chmod 700 "$WORK"
cp "$TRANSCRIPT" "$WORK/transcript.txt"

ARGS=(--harness-eval "$WORK/transcript.txt")
[ -n "$OUT" ] && ARGS+=(--out "$WORK/out")
"$BIN" "${ARGS[@]}" ${EXTRA[@]+"${EXTRA[@]}"} &
APP_PID=$!
wait "$APP_PID"; STATUS=$?
APP_PID=""
finish
exit "$STATUS"
