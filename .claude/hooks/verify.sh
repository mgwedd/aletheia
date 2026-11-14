#!/bin/bash
# PostToolUse hook (Edit|Write|MultiEdit): fast syntax check of the edited Swift file.
#
# Runs `swiftc -parse` on that one file (no type-check, no build). Catches syntax
# errors only. Imports, deleted-but-referenced symbols and lint need a real build
# (no swiftlint/swiftformat config exists in this repo), which is too slow here.
# Silent exit 0 on success, on non-Swift files, files outside the repo, or a missing
# tool. On failure: first 20 lines of the error to stderr, exit 2 so Claude sees it.
command -v jq >/dev/null 2>&1 || exit 0
command -v swiftc >/dev/null 2>&1 || exit 0

file=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ "$file" == *.swift && -f "$file" ]] || exit 0

root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$root" ] || exit 0
root=$(cd "$root" 2>/dev/null && pwd -P) || exit 0
real="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)/$(basename "$file")"
[[ "$real" == "$root"/* ]] || exit 0

to=$(command -v gtimeout || command -v timeout || true)
out=$(${to:+$to 10} swiftc -parse "$real" 2>&1)
rc=$?
[ $rc -eq 0 ] && exit 0
[ $rc -eq 124 ] && exit 0   # timed out: do not block on a slow check

{
  echo "swiftc -parse failed for ${real#$root/}:"
  echo "$out" | head -20
} >&2
exit 2
