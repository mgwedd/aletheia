#!/usr/bin/env bash
# Names on out-of-app surfaces go through PatientLabel.
#
# Fails if a source file that builds notifications, menu-bar text, Spotlight
# items, App Intents, calendar events or reminders reads a patient name directly
# (".name", "patientName", "displayName" in a string interpolation or a Text
# view, or any .name / patientName use in the Spotlight, Intents, Calendar and
# Reminders builders). Comment lines are ignored.
#
# Usage: scripts/check-patient-label.sh [repo-root]
#        scripts/check-patient-label.sh --self-test
set -euo pipefail

# Files where any .name / patientName use is a violation.
STRICT_DIRS=(Sources/App/Services/Spotlight Sources/App/Intents Sources/App/Services/Calendar Sources/App/Services/Reminders)
STRICT_FILES=(Sources/App/Services/SessionQueries.swift)
# Files where a name may not be interpolated or shown in Text(...).
INTERP_DIRS=(Sources/App/Services/Notifications)
INTERP_FILES=(Sources/App/Views/RecordingMenuBar.swift)

STRICT_RE='\.name\b|patientName'
INTERP_RE='\\\(\s*([A-Za-z_]+\.)*(name|patientName|displayName)\b|\bText\(\s*([A-Za-z_]+\.)*(name|patientName|displayName)\s*\)'

scan() { # root
  local root="$1" status=0 f
  check() { # file regex
    [ -f "$1" ] || { echo "missing: $1" >&2; status=1; return; }
    local hits
    hits=$(/usr/bin/grep -nE -- "$2" "$1" | /usr/bin/grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [ -n "$hits" ]; then
      echo "$1 shows a patient name directly; use PatientLabel:" >&2
      echo "$hits" >&2
      status=1
    fi
  }
  for d in "${STRICT_DIRS[@]}"; do
    for f in "$root/$d"/*.swift; do [ -e "$f" ] && check "$f" "$STRICT_RE"; done
  done
  for f in "${STRICT_FILES[@]}"; do check "$root/$f" "$STRICT_RE"; done
  for d in "${INTERP_DIRS[@]}"; do
    for f in "$root/$d"/*.swift; do [ -e "$f" ] && check "$f" "$INTERP_RE"; done
  done
  for f in "${INTERP_FILES[@]}"; do check "$root/$f" "$INTERP_RE"; done
  return $status
}

self_test() {
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  local d f
  for d in "${STRICT_DIRS[@]}" "${INTERP_DIRS[@]}" Sources/App/Views Sources/App/Services; do mkdir -p "$tmp/$d"; done
  for d in "${STRICT_DIRS[@]}" "${INTERP_DIRS[@]}"; do echo 'let x = PatientLabel(name: n).text' > "$tmp/$d/Ok.swift"; done
  for f in "${STRICT_FILES[@]}" "${INTERP_FILES[@]}"; do echo '// patient.name in a comment' > "$tmp/$f"; done
  scan "$tmp" 2>/dev/null || { echo "self-test: clean tree was rejected" >&2; exit 1; }
  echo 'let s = "Hi \(patient.name)"' > "$tmp/Sources/App/Services/Notifications/Bad.swift"
  if scan "$tmp" 2>/dev/null; then echo "self-test: notification interpolation not caught" >&2; exit 1; fi
  rm "$tmp/Sources/App/Services/Notifications/Bad.swift"
  echo 'Text(patient.name)' >> "$tmp/Sources/App/Views/RecordingMenuBar.swift"
  if scan "$tmp" 2>/dev/null; then echo "self-test: menu bar Text(name) not caught" >&2; exit 1; fi
  echo '// patient.name in a comment' > "$tmp/Sources/App/Views/RecordingMenuBar.swift"
  echo 'let n = session.patientName' > "$tmp/Sources/App/Intents/Bad.swift"
  if scan "$tmp" 2>/dev/null; then echo "self-test: intent patientName not caught" >&2; exit 1; fi
  echo "check-patient-label self-test passed"
}

case "${1:-}" in
  --self-test) self_test ;;
  *) root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
     scan "$root" && echo "check-patient-label: ok" ;;
esac
