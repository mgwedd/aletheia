#!/usr/bin/env bash
# Least-privilege guard for the app's sandbox entitlements.
#
# EventKit scheduling is a `.dev`-tier feature (EventKitSchedulingFeatureModule),
# so the production (Release) build must not request calendar access. The
# entitlements are chosen per build config in project.yml:
#
#   Release (production) -> Sources/App/Resources/Aletheia.entitlements     (no calendars)
#   Debug   (dev tier)   -> Sources/App/Resources/AletheiaDev.entitlements  (+ calendars)
#
# Network split: the main app has NO network entitlement. All networking runs
# in the bundled XPC helper (Sources/NetworkHelper), whose entitlements are
# exactly app-sandbox + network.client and nothing else.
#
# This script fails if:
#   - the production file contains the calendars entitlement,
#   - the dev file is missing it, or differs from production in any other key
#     (the two files must stay in sync),
#   - either main-app file contains com.apple.security.network.client,
#   - the helper's entitlements are anything other than app-sandbox and
#     network.client (both true),
#   - project.yml doesn't wire Release/Debug to those files (or sets
#     CODE_SIGN_ENTITLEMENTS in `base`, where a new config would inherit it),
#     or doesn't wire the helper target to its own file,
#   - the Xcode project sources stop excluding either file.
#
# Pure bash/awk/perl (no plutil), so it runs on the cheap Linux CI runner and on
# a Mac alike.
# Usage: scripts/check-entitlements.sh [--self-test]   (from anywhere)

set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "${CHECK_ENTITLEMENTS_ROOT:-$(dirname "$0")/..}"

if [ "${1:-}" = "--self-test" ]; then
    # Runs this script against mutated copies of the repo files and requires
    # each mutation to be caught (and the untouched copy to pass).
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    files="project.yml Sources/App/Resources/Aletheia.entitlements Sources/App/Resources/AletheiaDev.entitlements Sources/NetworkHelper/NetworkHelper.entitlements"
    failures=0
    fresh() {
        rm -rf "$tmp/repo"; mkdir -p "$tmp/repo"
        for f in $files; do mkdir -p "$tmp/repo/$(dirname "$f")"; cp "$f" "$tmp/repo/$f"; done
    }
    run() { CHECK_ENTITLEMENTS_ROOT="$tmp/repo" "$SCRIPT" >/dev/null 2>&1; }
    expect_pass() {
        fresh
        if run; then echo "ok   $1"; else echo "FAIL $1 (expected pass)"; failures=$((failures + 1)); fi
    }
    # expect_fail <name> <file> <perl substitution>
    expect_fail() {
        fresh
        perl -0777 -i -pe "$3" "$tmp/repo/$2"
        if run; then echo "FAIL $1 (not caught)"; failures=$((failures + 1)); else echo "ok   $1"; fi
    }
    NETKEY='<key>com.apple.security.network.client</key><true/>'
    APP=Sources/App/Resources/Aletheia.entitlements
    DEVF=Sources/App/Resources/AletheiaDev.entitlements
    HELP=Sources/NetworkHelper/NetworkHelper.entitlements

    expect_pass "repo files pass"
    expect_fail "network.client in the production app" "$APP" "s|</dict>|$NETKEY</dict>|"
    expect_fail "network.client in the dev app" "$DEVF" "s|</dict>|$NETKEY</dict>|"
    expect_fail "helper loses network.client" "$HELP" 's|<key>com.apple.security.network.client</key>\s*<true/>||'
    expect_fail "helper loses the sandbox" "$HELP" 's|<key>com.apple.security.app-sandbox</key>\s*<true/>||'
    expect_fail "helper network.client set false" "$HELP" 's|(network.client</key>\s*)<true/>|$1<false/>|'
    expect_fail "helper gains file access" "$HELP" 's|</dict>|<key>com.apple.security.files.user-selected.read-write</key><true/></dict>|'
    expect_fail "helper gains the microphone" "$HELP" 's|</dict>|<key>com.apple.security.device.audio-input</key><true/></dict>|'
    expect_fail "helper entitlements unwired" project.yml 's|CODE_SIGN_ENTITLEMENTS: Sources/NetworkHelper/NetworkHelper.entitlements||'
    expect_fail "calendars in the production app" "$APP" 's|</dict>|<key>com.apple.security.personal-information.calendars</key><true/></dict>|'

    if [ "$failures" -ne 0 ]; then
        echo "check-entitlements self-test: $failures failure(s)" >&2
        exit 1
    fi
    echo "check-entitlements self-test: OK"
    exit 0
fi

PROD="Sources/App/Resources/Aletheia.entitlements"
DEV="Sources/App/Resources/AletheiaDev.entitlements"
HELPER="Sources/NetworkHelper/NetworkHelper.entitlements"
CAL="com.apple.security.personal-information.calendars"
NET="com.apple.security.network.client"
SANDBOX="com.apple.security.app-sandbox"
fail=0
err() { echo "check-entitlements: $*" >&2; fail=1; }

# Sorted entitlement keys of a plist, ignoring XML comments (which may mention keys).
keys() {
    perl -0777 -pe 's/<!--.*?-->//gs' "$1" | grep -o '<key>[^<]*</key>' | sed -e 's/<key>//' -e 's/<\/key>//' | sort
}

for f in "$PROD" "$DEV" "$HELPER"; do
    [ -f "$f" ] || err "missing $f"
done
[ "$fail" -eq 0 ] || exit 1

prod_keys="$(keys "$PROD")"
dev_keys="$(keys "$DEV")"

if grep -qx "$CAL" <<<"$prod_keys"; then
    err "$PROD must NOT contain $CAL (production ships no EventKit feature)"
fi
if ! grep -qx "$CAL" <<<"$dev_keys"; then
    err "$DEV must contain $CAL (dev tier ships EventKit scheduling)"
fi
expected_dev="$(printf '%s\n%s\n' "$prod_keys" "$CAL" | sort -u)"
if [ "$dev_keys" != "$expected_dev" ]; then
    err "$DEV must be exactly $PROD plus $CAL; key sets differ:"
    diff <(echo "$expected_dev") <(echo "$dev_keys") >&2 || true
fi

# The main app has no network entitlement.
for f in "$PROD" "$DEV"; do
    if keys "$f" | grep -qx "$NET"; then
        err "$f must NOT contain $NET (all networking lives in the helper)"
    fi
done

# The helper has exactly the sandbox and network.client, both true.
helper_keys="$(keys "$HELPER")"
expected_helper="$(printf '%s\n%s\n' "$SANDBOX" "$NET" | sort -u)"
if [ "$helper_keys" != "$expected_helper" ]; then
    err "$HELPER must contain exactly $SANDBOX and $NET; got:"
    echo "$helper_keys" >&2
fi
helper_flat="$(perl -0777 -pe 's/<!--.*?-->//gs' "$HELPER" | tr -d '[:space:]')"
for k in "$SANDBOX" "$NET"; do
    case "$helper_flat" in
        *"<key>$k</key><true/>"*) ;;
        *) err "$HELPER: $k must be <true/>" ;;
    esac
done

# project.yml wiring: CODE_SIGN_ENTITLEMENTS per config, never in `base`.
# Track the enclosing target (2-space indent) and `base:` / `Debug:` / `Release:` block as awk walks the file.
wiring="$(awk '
    /^  [A-Za-z]+:[[:space:]]*$/ { target=$1 }
    target == "Aletheia:" && /^[[:space:]]*(base|Debug|Release):[[:space:]]*$/ { blk=$1; sub(/:$/, "", blk) }
    target == "Aletheia:" && /^[[:space:]]*CODE_SIGN_ENTITLEMENTS:/ { print blk "=" $2 }
' project.yml)"
grep -qx "Release=$PROD" <<<"$wiring" || err "project.yml: Release must set CODE_SIGN_ENTITLEMENTS to $PROD"
grep -qx "Debug=$DEV" <<<"$wiring"    || err "project.yml: Debug must set CODE_SIGN_ENTITLEMENTS to $DEV"
if grep -q '^base=' <<<"$wiring"; then
    err "project.yml: don't set CODE_SIGN_ENTITLEMENTS in base (per-config only)"
fi
if [ "$(grep -c . <<<"$wiring")" -ne 2 ]; then
    err "project.yml: expected exactly two CODE_SIGN_ENTITLEMENTS settings (Debug, Release); got: $(echo $wiring)"
fi

# The helper target is wired to its own entitlements file.
helper_wiring="$(awk '
    /^  [A-Za-z]+:[[:space:]]*$/ { target=$1 }
    target == "AletheiaNetworkHelper:" && /^[[:space:]]*CODE_SIGN_ENTITLEMENTS:/ { print $2 }
' project.yml)"
[ "$helper_wiring" = "$HELPER" ] || err "project.yml: AletheiaNetworkHelper must set CODE_SIGN_ENTITLEMENTS to $HELPER (got: ${helper_wiring:-nothing})"

for f in Aletheia.entitlements AletheiaDev.entitlements; do
    grep -q "\"Resources/$f\"" project.yml || err "project.yml: sources must exclude Resources/$f"
done

if [ "$fail" -ne 0 ]; then
    echo "check-entitlements: FAILED" >&2
    exit 1
fi
echo "check-entitlements: OK (app: no network, production: no calendars; helper: sandbox + network only)"
