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
# It also fails if the shared Info.plist carries the Calendar or Reminders
# purpose strings outside the dev-tier block (#ifdef ALETHEIA_DEV), or if
# project.yml defines ALETHEIA_DEV for anything but Debug.
#
# Pure bash/awk/perl (plutil is used only when present), so it runs on the cheap
# Linux CI runner and on a Mac alike.
#
# Usage: scripts/check-entitlements.sh               (source checks, from anywhere)
#        scripts/check-entitlements.sh --app <path.app>
#            checks a built production app: its signed entitlement keys equal the
#            production file's exactly, its Info.plist has no Calendar/Reminders
#            purpose strings, and its executable has no debug-only `--harness` flags.
#        scripts/check-entitlements.sh --self-test

set -euo pipefail
cd "$(dirname "$0")/.."

ROOT="$PWD"
PROD="${PROD:-Sources/App/Resources/Aletheia.entitlements}"
DEV="${DEV:-Sources/App/Resources/AletheiaDev.entitlements}"
INFO="${INFO:-Sources/App/Resources/Info.plist}"
PROJECT="${PROJECT:-project.yml}"
CAL="com.apple.security.personal-information.calendars"
fail=0
err() { echo "check-entitlements: $*" >&2; fail=1; }

# Sorted entitlement keys of a plist, ignoring XML comments (which may mention keys).
keys() {
    perl -0777 -pe 's/<!--.*?-->//gs' "$1" | grep -o '<key>[^<]*</key>' | sed -e 's/<key>//' -e 's/<\/key>//' | sort
}

# ---- --app: check a built production app ------------------------------------
check_app() {
    local app="$1" tmp info bin found=0
    [ -d "$app" ] || { err "no app at $app"; return; }
    [ -f "$PROD" ] || { err "missing $PROD"; return; }
    tmp="$(mktemp -d)"
    # Clear the trap as it fires: a RETURN trap outlives the function otherwise.
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN

    # Signed entitlement keys must equal the production file's, exactly.
    "${CODESIGN:-codesign}" -d --entitlements :- "$app" > "$tmp/ent.plist" 2>/dev/null || true
    local want got
    want="$(keys "$PROD")"
    # An unsigned app prints no entitlements: no keys, so the diff below fails it.
    got="$(keys "$tmp/ent.plist" || true)"
    if [ "$got" != "$want" ]; then
        err "$app: signed entitlements differ from $PROD (< expected, > built):"
        diff <(echo "$want") <(echo "$got") >&2 || true
    fi

    # No Calendar/Reminders purpose strings in the shipped Info.plist.
    info="$app/Contents/Info.plist"
    if [ ! -f "$info" ]; then
        err "$app: no Contents/Info.plist"
    else
        if command -v plutil >/dev/null 2>&1; then
            plutil -convert xml1 -o "$tmp/info.plist" "$info" 2>/dev/null || cp "$info" "$tmp/info.plist"
        else
            cp "$info" "$tmp/info.plist"
        fi
        if keys "$tmp/info.plist" | grep -Eq '^NS(Calendars|Reminders)[A-Za-z]*UsageDescription$'; then
            err "$app: Info.plist carries Calendar/Reminders usage descriptions (dev tier only)"
        fi
    fi

    # Debug-only launch flags must be compiled out of the executable.
    for bin in "$app"/Contents/MacOS/*; do
        [ -f "$bin" ] || continue
        found=1
        if grep -aq -e '--harness' "$bin"; then
            err "$bin: contains the debug-only --harness flags"
        fi
    done
    [ "$found" -eq 1 ] || err "$app: no executable in Contents/MacOS"
}

if [ "${1:-}" = "--app" ]; then
    check_app "${2:?usage: check-entitlements.sh --app <path.app>}"
    if [ "$fail" -ne 0 ]; then
        echo "check-entitlements: FAILED" >&2
        exit 1
    fi
    echo "check-entitlements: OK ($2: entitlements match production; no calendar strings; no harness flags)"
    exit 0
fi

# ---- --self-test: fixtures, one passing and one failing per rule -----------
self_test() {
    local d bad=0 script="$ROOT/scripts/check-entitlements.sh"
    d="$(mktemp -d)"
    trap 'rm -rf "$d"; trap - RETURN' RETURN
    ent() { # ent <file> <key>...
        local f="$1"; shift
        { echo '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
          for k in "$@"; do echo "<key>$k</key><true/>"; done
          echo '</dict></plist>'; } > "$f"
    }
    ent "$d/prod.ent" a.sandbox a.audio
    ent "$d/dev.ent" a.sandbox a.audio "$CAL"
    printf '%s\n' '<dict>' '<key>CFBundleName</key><string>x</string>' '#ifdef ALETHEIA_DEV' \
        '<key>NSCalendarsFullAccessUsageDescription</key><string>x</string>' '#endif' '</dict>' > "$d/Info.plist"
    printf '%s\n' 'targets:' '  A:' '    settings:' '      configs:' '        Debug:' \
        "          CODE_SIGN_ENTITLEMENTS: $d/dev.ent" '          INFOPLIST_PREPROCESSOR_DEFINITIONS: ALETHEIA_DEV=1' \
        '        Release:' "          CODE_SIGN_ENTITLEMENTS: $d/prod.ent" \
        '"Resources/Aletheia.entitlements"' '"Resources/AletheiaDev.entitlements"' > "$d/project.yml"
    run_static() { PROD="$d/prod.ent" DEV="$d/dev.ent" INFO="$d/Info.plist" PROJECT="$d/project.yml" "$script" >/dev/null 2>&1; }
    run_static || { echo "check-entitlements: self-test: clean fixtures should pass" >&2; bad=1; }

    # A Reminders string outside the dev block.
    cp "$d/Info.plist" "$d/Info.good"
    printf '%s\n' '<dict>' '<key>NSRemindersFullAccessUsageDescription</key><string>x</string>' '</dict>' > "$d/Info.plist"
    run_static && { echo "check-entitlements: self-test: Reminders string outside the dev block was accepted" >&2; bad=1; }
    cp "$d/Info.good" "$d/Info.plist"

    # ALETHEIA_DEV defined for Release as well.
    cp "$d/project.yml" "$d/project.good"
    printf '%s\n' '        Release:' '          INFOPLIST_PREPROCESSOR_DEFINITIONS: ALETHEIA_DEV=1' >> "$d/project.yml"
    run_static && { echo "check-entitlements: self-test: ALETHEIA_DEV in Release was accepted" >&2; bad=1; }
    cp "$d/project.good" "$d/project.yml"

    # --app fixtures: a fake app, and a stub codesign that prints a fixture.
    mkdir -p "$d/App.app/Contents/MacOS"
    printf 'plain binary\n' > "$d/App.app/Contents/MacOS/App"
    printf '%s\n' '<dict><key>CFBundleName</key><string>x</string></dict>' > "$d/App.app/Contents/Info.plist"
    printf '#!/bin/sh\ncat "$ENT_FIXTURE"\n' > "$d/codesign"; chmod +x "$d/codesign"
    run_app() { CODESIGN="$d/codesign" ENT_FIXTURE="$1" PROD="$d/prod.ent" "$script" --app "$d/App.app" >/dev/null 2>&1; }
    run_app "$d/prod.ent" || { echo "check-entitlements: self-test: matching app should pass" >&2; bad=1; }
    ent "$d/extra.ent" a.sandbox a.audio a.extra
    run_app "$d/extra.ent" && { echo "check-entitlements: self-test: an extra entitlement key was accepted" >&2; bad=1; }
    ent "$d/missing.ent" a.sandbox
    run_app "$d/missing.ent" && { echo "check-entitlements: self-test: a missing entitlement key was accepted" >&2; bad=1; }
    printf '#!/bin/sh\nexit 1\n' > "$d/unsigned"; chmod +x "$d/unsigned"
    if CODESIGN="$d/unsigned" PROD="$d/prod.ent" "$script" --app "$d/App.app" 2>"$d/err" >/dev/null \
        || ! grep -q 'signed entitlements differ' "$d/err"; then
        echo "check-entitlements: self-test: an unsigned app was not refused with a message" >&2; bad=1
    fi
    ent "$d/tka.ent" a.sandbox a.audio com.apple.security.get-task-allow
    run_app "$d/tka.ent" && { echo "check-entitlements: self-test: get-task-allow was accepted" >&2; bad=1; }
    printf '%s\n' '<dict><key>NSCalendarsFullAccessUsageDescription</key><string>x</string></dict>' > "$d/App.app/Contents/Info.plist"
    run_app "$d/prod.ent" && { echo "check-entitlements: self-test: a Calendar string in the app was accepted" >&2; bad=1; }
    printf '%s\n' '<dict><key>CFBundleName</key><string>x</string></dict>' > "$d/App.app/Contents/Info.plist"
    printf 'xx --harness-record xx\n' > "$d/App.app/Contents/MacOS/App"
    run_app "$d/prod.ent" && { echo "check-entitlements: self-test: a --harness flag in the binary was accepted" >&2; bad=1; }

    [ "$bad" -eq 0 ] || return 1
    echo "check-entitlements: self-test OK"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

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
' "$PROJECT")"
grep -qx "Release=$PROD" <<<"$wiring" || err "project.yml: Release must set CODE_SIGN_ENTITLEMENTS to $PROD"
grep -qx "Debug=$DEV" <<<"$wiring"    || err "project.yml: Debug must set CODE_SIGN_ENTITLEMENTS to $DEV"
if grep -q '^base=' <<<"$wiring"; then
    err "project.yml: don't set CODE_SIGN_ENTITLEMENTS in base (per-config only)"
fi
if [ "$(grep -c . <<<"$wiring")" -ne 2 ]; then
    err "project.yml: expected exactly two CODE_SIGN_ENTITLEMENTS settings (Debug, Release); got: $(echo $wiring)"
fi

for f in Aletheia.entitlements AletheiaDev.entitlements; do
    grep -q "\"Resources/$f\"" "$PROJECT" || err "project.yml: sources must exclude Resources/$f"
done

# Calendar/Reminders purpose strings only inside the dev-tier #ifdef block.
if [ -f "$INFO" ]; then
    if perl -0777 -pe 's/#ifdef ALETHEIA_DEV.*?#endif//gs; s/<!--.*?-->//gs' "$INFO" \
        | grep -Eq '<key>NS(Calendars|Reminders)[A-Za-z]*UsageDescription</key>'; then
        err "$INFO: Calendar/Reminders usage descriptions must sit inside #ifdef ALETHEIA_DEV"
    fi
else
    err "missing $INFO"
fi
# ALETHEIA_DEV is defined for Debug only.
defs="$(awk '
    /^[[:space:]]*(base|Debug|Release):[[:space:]]*$/ { blk=$1; sub(/:$/, "", blk) }
    /^[[:space:]]*INFOPLIST_PREPROCESSOR_DEFINITIONS:/ { print blk "=" $2 }
' "$PROJECT")"
grep -qx "Debug=ALETHEIA_DEV=1" <<<"$defs" || err "$PROJECT: Debug must set INFOPLIST_PREPROCESSOR_DEFINITIONS: ALETHEIA_DEV=1"
if grep -qv '^Debug=' <<<"$defs"; then
    err "$PROJECT: only Debug may set INFOPLIST_PREPROCESSOR_DEFINITIONS (got: $(echo $defs))"
fi

if [ "$fail" -ne 0 ]; then
    echo "check-entitlements: FAILED" >&2
    exit 1
fi
echo "check-entitlements: OK (production: no calendars; dev: +calendars only)"
