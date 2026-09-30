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
# This script fails if:
#   - the production file contains the calendars entitlement,
#   - the dev file is missing it, or differs from production in any other key
#     (the two files must stay in sync),
#   - project.yml doesn't wire Release/Debug to those files (or sets
#     CODE_SIGN_ENTITLEMENTS in `base`, where a new config would inherit it),
#   - the Xcode project sources stop excluding either file.
#
# Pure bash/awk/perl (no plutil), so it runs on the cheap Linux CI runner and on
# a Mac alike. Usage: scripts/check-entitlements.sh   (from anywhere)

set -euo pipefail
cd "$(dirname "$0")/.."

PROD="Sources/App/Resources/Aletheia.entitlements"
DEV="Sources/App/Resources/AletheiaDev.entitlements"
CAL="com.apple.security.personal-information.calendars"
fail=0
err() { echo "check-entitlements: $*" >&2; fail=1; }

# Sorted entitlement keys of a plist, ignoring XML comments (which may mention keys).
keys() {
    perl -0777 -pe 's/<!--.*?-->//gs' "$1" | grep -o '<key>[^<]*</key>' | sed -e 's/<key>//' -e 's/<\/key>//' | sort
}

for f in "$PROD" "$DEV"; do
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

# project.yml wiring: CODE_SIGN_ENTITLEMENTS per config, never in `base`.
# Track the enclosing `base:` / `Debug:` / `Release:` block as awk walks the file.
wiring="$(awk '
    /^[[:space:]]*(base|Debug|Release):[[:space:]]*$/ { blk=$1; sub(/:$/, "", blk) }
    /^[[:space:]]*CODE_SIGN_ENTITLEMENTS:/ { print blk "=" $2 }
' project.yml)"
grep -qx "Release=$PROD" <<<"$wiring" || err "project.yml: Release must set CODE_SIGN_ENTITLEMENTS to $PROD"
grep -qx "Debug=$DEV" <<<"$wiring"    || err "project.yml: Debug must set CODE_SIGN_ENTITLEMENTS to $DEV"
if grep -q '^base=' <<<"$wiring"; then
    err "project.yml: don't set CODE_SIGN_ENTITLEMENTS in base (per-config only)"
fi
if [ "$(grep -c . <<<"$wiring")" -ne 2 ]; then
    err "project.yml: expected exactly two CODE_SIGN_ENTITLEMENTS settings (Debug, Release); got: $(echo $wiring)"
fi

for f in Aletheia.entitlements AletheiaDev.entitlements; do
    grep -q "\"Resources/$f\"" project.yml || err "project.yml: sources must exclude Resources/$f"
done

if [ "$fail" -ne 0 ]; then
    echo "check-entitlements: FAILED" >&2
    exit 1
fi
echo "check-entitlements: OK (production: no calendars; dev: +calendars only)"
