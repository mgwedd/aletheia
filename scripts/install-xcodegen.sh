#!/usr/bin/env bash
# Installs the XcodeGen release pinned in scripts/tools.lock, verifying its
# SHA-256 before unpacking. No package manager, so nothing floats.
#
# Usage: scripts/install-xcodegen.sh --dest DIR [--from-file ZIP]
#        scripts/install-xcodegen.sh --self-test
#   Prints the directory to put on PATH (DIR/xcodegen/bin).
#   --from-file  verify and unpack a zip you already have instead of downloading.
#   $TOOLS_LOCK  overrides the lock file (used by the self-test).

set -euo pipefail
cd "$(dirname "$0")/.."

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

install_tool() { # install_tool <dest> [zip]
    local dest="$1" zip="${2:-}" lock="${TOOLS_LOCK:-scripts/tools.lock}" want url tmp
    read -r want url < <(awk '$1 == "xcodegen" {print $3, $4}' "$lock")
    [ -n "${want:-}" ] && [ -n "${url:-}" ] || { echo "install-xcodegen: no xcodegen entry in $lock" >&2; return 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    if [ -z "$zip" ]; then
        curl -fsSL --retry 3 -o "$tmp/xcodegen.zip" "$url"
        zip="$tmp/xcodegen.zip"
    fi
    if [ "$(sha256 "$zip")" != "$want" ]; then
        echo "install-xcodegen: SHA-256 of the XcodeGen download does not match $lock" >&2
        return 1
    fi
    mkdir -p "$dest"
    rm -rf "$dest/xcodegen"
    unzip -q "$zip" -d "$dest"
    [ -x "$dest/xcodegen/bin/xcodegen" ] || { echo "install-xcodegen: xcodegen binary missing from the archive" >&2; return 1; }
    echo "$dest/xcodegen/bin"
}

self_test() {
    local d fail=0
    d="$(mktemp -d)"
    trap 'rm -rf "$d"' RETURN
    mkdir -p "$d/z/xcodegen/bin"
    printf '#!/bin/sh\necho ok\n' > "$d/z/xcodegen/bin/xcodegen"
    chmod +x "$d/z/xcodegen/bin/xcodegen"
    (cd "$d/z" && zip -qr ../good.zip xcodegen)
    printf 'xcodegen 0 %s file:///unused\n' "$(sha256 "$d/good.zip")" > "$d/ok.lock"
    printf 'xcodegen 0 %064d file:///unused\n' 0 > "$d/bad.lock"
    TOOLS_LOCK="$d/ok.lock" install_tool "$d/out" "$d/good.zip" >/dev/null \
        || { echo "install-xcodegen: self-test: a matching archive was refused" >&2; fail=1; }
    [ -x "$d/out/xcodegen/bin/xcodegen" ] || { echo "install-xcodegen: self-test: not unpacked" >&2; fail=1; }
    if TOOLS_LOCK="$d/bad.lock" install_tool "$d/out2" "$d/good.zip" >/dev/null 2>&1; then
        echo "install-xcodegen: self-test: a mismatched archive was accepted" >&2; fail=1
    fi
    [ ! -e "$d/out2" ] || { echo "install-xcodegen: self-test: mismatched archive was unpacked" >&2; fail=1; }
    [ "$fail" -eq 0 ] || return 1
    echo "install-xcodegen: self-test OK"
}

DEST=""; FROM=""
while [ $# -gt 0 ]; do
    case "$1" in
        --self-test) self_test; exit $? ;;
        --dest) DEST="$2"; shift 2 ;;
        --from-file) FROM="$2"; shift 2 ;;
        *) echo "install-xcodegen: unknown argument $1" >&2; exit 2 ;;
    esac
done
[ -n "$DEST" ] || { echo "usage: install-xcodegen.sh --dest DIR [--from-file ZIP] | --self-test" >&2; exit 2; }
install_tool "$DEST" "$FROM"
