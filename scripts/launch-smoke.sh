#!/usr/bin/env bash
# Launches a packaged Aletheia.app and fails if it doesn't stay up.
#
# The unit tests run a Debug build with Hardened Runtime off (so XCTest can
# attach). The build users get is Release, sandboxed and Hardened Runtime, so
# a missing entitlement or a library the runtime refuses to load only shows up
# when that build starts. This starts it, waits, and checks the process is
# still alive and that no crash report for it appeared.
#
# Usage: scripts/launch-smoke.sh <path/to/Aletheia.app | path/to/Aletheia.dmg>
#        scripts/launch-smoke.sh --self-test
# LAUNCH_SMOKE_SECONDS (default 20) sets how long the app must stay up.

set -euo pipefail

SECONDS_UP="${LAUNCH_SMOKE_SECONDS:-20}"

# CFBundleExecutable from an app's Info.plist (python3 reads plists on macOS
# and Linux alike, so the self-test runs anywhere).
bundle_executable() {
    python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb"))["CFBundleExecutable"])' \
        "$1/Contents/Info.plist"
}

# Crash reports for this executable newer than the marker file.
crash_reports_since() {
    local name="$1" marker="$2" dir
    for dir in "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports; do
        [ -d "$dir" ] || continue
        find "$dir" -maxdepth 1 -type f \( -name "${name}*.ips" -o -name "${name}*.crash" \) -newer "$marker" 2>/dev/null
    done
}

# Launches the app at $1 and checks it. Returns 0 when it stayed up.
check_app() {
    local app="$1" name exe log marker pid reports
    [ -d "$app" ] || { echo "launch-smoke: no app at $app" >&2; return 1; }
    name="$(bundle_executable "$app")"
    exe="$app/Contents/MacOS/$name"
    [ -x "$exe" ] || { echo "launch-smoke: $exe is not executable" >&2; return 1; }

    log="$(mktemp)"
    marker="$(mktemp)"
    "$exe" >"$log" 2>&1 &
    pid=$!
    sleep "$SECONDS_UP"

    if ! kill -0 "$pid" 2>/dev/null; then
        wait "$pid" && status=0 || status=$?
        echo "launch-smoke: $name exited within ${SECONDS_UP}s (status $status). Output:" >&2
        cat "$log" >&2
        crash_reports_since "$name" "$marker" | while read -r r; do echo "--- $r" >&2; head -n 80 "$r" >&2; done
        rm -f "$log" "$marker"
        return 1
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    reports="$(crash_reports_since "$name" "$marker")"
    rm -f "$log" "$marker"
    if [ -n "$reports" ]; then
        echo "launch-smoke: $name stayed up but left crash reports:" >&2
        echo "$reports" >&2
        return 1
    fi
    echo "launch-smoke: $name stayed up for ${SECONDS_UP}s"
}

# Fake bundles whose executable stays up, or exits at once.
self_test() {
    local dir fail=0
    dir="$(mktemp -d)"
    trap 'rm -rf "$dir"' RETURN
    make_app() { # make_app <dir> <script body>
        mkdir -p "$1/Contents/MacOS"
        python3 -I -c 'import plistlib,sys; plistlib.dump({"CFBundleExecutable":"Fake"}, open(sys.argv[1],"wb"))' \
            "$1/Contents/Info.plist"
        printf '#!/bin/sh\n%s\n' "$2" > "$1/Contents/MacOS/Fake"
        chmod +x "$1/Contents/MacOS/Fake"
    }
    make_app "$dir/Up.app" 'sleep 30'
    make_app "$dir/Dies.app" 'echo "dyld: Library not loaded" >&2; exit 1'
    SECONDS_UP=1
    check_app "$dir/Up.app" >/dev/null || { echo "launch-smoke self-test: an app that stays up failed" >&2; fail=1; }
    if check_app "$dir/Dies.app" >/dev/null 2>&1; then
        echo "launch-smoke self-test: an app that exits passed" >&2; fail=1
    fi
    if check_app "$dir/Missing.app" >/dev/null 2>&1; then
        echo "launch-smoke self-test: a missing app passed" >&2; fail=1
    fi
    [ "$fail" -eq 0 ] && echo "launch-smoke: self-test OK"
    return "$fail"
}

TARGET="${1:?usage: launch-smoke.sh <app|dmg> | --self-test}"
if [ "$TARGET" = "--self-test" ]; then
    self_test
    exit $?
fi

case "$TARGET" in
    *.dmg)
        # Copy the app out of a read-only mount, as a user would drag it.
        MOUNT="$(mktemp -d)"
        COPY="$(mktemp -d)"
        hdiutil attach "$TARGET" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
        APP_IN_DMG="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -n 1)"
        cp -R "$APP_IN_DMG" "$COPY/"
        hdiutil detach "$MOUNT" >/dev/null
        check_app "$COPY/$(basename "$APP_IN_DMG")"
        ;;
    *)
        check_app "$TARGET"
        ;;
esac
