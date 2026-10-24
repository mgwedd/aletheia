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
# Security settings get the same treatment:
#
#   scripts/audit-security-settings.txt key ──▶ its `@Published var` didSet in
#                              AppSettings.swift calls `audited(`? no ──▶ fail
#   AuditedSettings.<name> declared but never referenced ──▶ fail
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
    done < <(sed -n '/enum AuditAction/,/^[[:space:]]*}/ s/^[[:space:]]*case \([A-Za-z]*\)$/\1/p' "$def")
    return $bad
}

# check_settings <AppSettings.swift> <keys-list> <sources-dir> <AuditedSetting.swift>
check_settings() {
    local file=$1 list=$2 src=$3 defs=$4 bad=0 key name
    while IFS= read -r key; do
        if ! awk -v k="$key" '
            $0 ~ "@Published var " k "[ :]" { on = 1; found = 1 }
            on && /audited\(/ { ok = 1 }
            on && /^    }[[:space:]]*$/ { on = 0 }
            on && /^    @Published|^    var |^    let / && $0 !~ "@Published var " k "[ :]" { on = 0 }
            END { exit !(found && ok) }' "$file"; then
            echo "Setting $key changes without audited(...) in its didSet (see scripts/audit-security-settings.txt)"; bad=1
        fi
    done < <(grep -vE '^[[:space:]]*(#|$)' "$list")
    while IFS= read -r name; do
        if ! grep -rqE "AuditedSettings\.${name}\b" "$src" --include='*.swift' --exclude="$(basename "$defs")"; then
            echo "AuditedSettings.$name is never used; route its setting through audited(...)"; bad=1
        fi
    done < <(sed -n 's/^[[:space:]]*static let \([A-Za-z]*\) = AuditedSetting<.*/\1/p' "$defs")
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
    printf '    @Published var good: Bool {\n        didSet {\n            defaults.set(good)\n            audited(AuditedSettings.one, from: o, to: good)\n        }\n    }\n    @Published var bad: Bool {\n        didSet { defaults.set(bad) }\n    }\n    @Published var other: Bool {\n        didSet { audited(AuditedSettings.two, from: o, to: other) }\n    }\n' > "$t/Settings.swift"
    printf '    static let one = AuditedSetting<Bool>(name: "One", describe: f)\n    static let two = AuditedSetting<Bool>(name: "Two", describe: f)\n    static let unused = AuditedSetting<Bool>(name: "Unused", describe: f)\n' > "$t/AuditedSetting.swift"
    printf 'x(AuditedSettings.one)\ny(AuditedSettings.two)\n' > "$t/Use2.swift"
    printf 'good\nbad\n' > "$t/keys.txt"
    out=$(check_settings "$t/Settings.swift" "$t/keys.txt" "$t" "$t/AuditedSetting.swift" || true)
    echo "$out" | grep -q 'Setting bad changes without' || { echo "self-test: unaudited setting not flagged"; exit 1; }
    echo "$out" | grep -q 'Setting good' && { echo "self-test: audited setting flagged"; exit 1; }
    echo "$out" | grep -q 'AuditedSettings.unused is never used' || { echo "self-test: unused declaration not flagged"; exit 1; }
    echo "$out" | grep -q 'AuditedSettings.one ' && { echo "self-test: used declaration flagged"; exit 1; }
    echo "audit wiring guard self-test passed"; exit 0
fi

def=$(grep -rl 'enum AuditAction' Sources | head -1)
status=0
check "$def" Sources scripts/audit-unwired.txt || status=1
check_settings Sources/App/Services/AppSettings.swift scripts/audit-security-settings.txt Sources \
    Sources/App/Services/AuditedSetting.swift || status=1
if [ "$status" = 0 ]; then echo "audit wiring OK"; else exit 1; fi
