#!/usr/bin/env bash
# Audit guard: every `AuditAction` case must be recorded somewhere.
#
#   AuditLog.swift cases ──▶ referenced as `.case` elsewhere in Sources?
#                              no, and not in audit-unwired.txt ──▶ fail
#                              yes, but listed in audit-unwired.txt ──▶ fail (stale)
#
# The log's own tests cover storage; nothing else notices an action that is
# defined but never recorded, which left the Security Audit Log empty.
#
# Usage: scripts/check-audit-wiring.sh [--self-test]   (from anywhere)

set -euo pipefail
cd "$(dirname "$0")/.."

# check <audit-file> <sources-dir> <allowlist>; prints problems, returns 1 if any.
check() {
    local def=$1 src=$2 allow=$3 bad=0 name
    while IFS= read -r name; do
        local used listed=0
        used=$(grep -rE "\.${name}\b" "$src" --include='*.swift' --exclude="$(basename "$def")" -l | head -1 || true)
        grep -qxF "$name" <(grep -vE '^[[:space:]]*(#|$)' "$allow") && listed=1
        if [ -z "$used" ] && [ "$listed" = 0 ]; then
            echo "AuditAction.$name is never recorded (wire it, or list it in scripts/audit-unwired.txt)"; bad=1
        elif [ -n "$used" ] && [ "$listed" = 1 ]; then
            echo "AuditAction.$name is recorded now; remove it from scripts/audit-unwired.txt"; bad=1
        fi
    done < <(sed -n 's/^[[:space:]]*case \([A-Za-z]*\)$/\1/p' "$def")
    return $bad
}

if [ "${1:-}" = "--self-test" ]; then
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    printf 'enum AuditAction {\n    case wired\n    case orphan\n    case stale\n}\n' > "$t/AuditLog.swift"
    printf 'x.recordAudit(.wired)\ny.record(.stale)\n' > "$t/Use.swift"
    printf 'stale\n' > "$t/allow.txt"
    out=$(check "$t/AuditLog.swift" "$t" "$t/allow.txt" || true)
    echo "$out" | grep -q 'orphan is never recorded' || { echo "self-test: orphan not flagged"; exit 1; }
    echo "$out" | grep -q 'stale is recorded now' || { echo "self-test: stale entry not flagged"; exit 1; }
    echo "$out" | grep -q 'AuditAction.wired ' && { echo "self-test: wired case flagged"; exit 1; }
    echo "audit wiring guard self-test passed"; exit 0
fi

def=$(grep -rl 'enum AuditAction' Sources | head -1)
if check "$def" Sources scripts/audit-unwired.txt; then echo "audit wiring OK"; else exit 1; fi
