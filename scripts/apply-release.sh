#!/bin/bash
# Applies a computed release version to the repo, ready to commit and tag.
# Called by .github/workflows/auto-release.yml after compute-release.sh.
#
#   1. Sets Info.plist's CFBundleShortVersionString to the new version and
#      CFBundleVersion to a monotonic build number (the commit count), so the
#      shipped app reports the version being released and the in-app updater's
#      version comparison is meaningful.
#   2. Inserts a CHANGELOG.md section for the version, generated from the
#      Conventional Commit subjects since the last tag (see changelog-section.sh).
#      CHANGELOG.md is never hand-edited in PRs, so it can't cause conflicts.
#
# Pure awk/sed + git — no third-party tools. Idempotent enough to re-run.
#
# Usage: scripts/apply-release.sh <version>   e.g. scripts/apply-release.sh 1.1.0

set -euo pipefail

VERSION="${1:?usage: apply-release.sh <version>}"
VERSION="${VERSION#v}"
cd "$(dirname "$0")/.."

INFO_PLIST="SessionNotes/Sources/SessionNotesApp/Resources/Info.plist"
CHANGELOG="CHANGELOG.md"
BUILD_NUMBER="$(git rev-list --count HEAD)"
TODAY="$(date -u +%Y-%m-%d)"

# --- Info.plist: set the <string> on the line following each version key. ---
set_plist_string() {
    local key="$1" value="$2" tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        prev ~ "<key>" key "</key>" {
            sub(/<string>[^<]*<\/string>/, "<string>" value "</string>")
        }
        { print; prev = $0 }
    ' "$INFO_PLIST" > "$tmp"
    mv "$tmp" "$INFO_PLIST"
}

set_plist_string "CFBundleShortVersionString" "$VERSION"
set_plist_string "CFBundleVersion" "$BUILD_NUMBER"

# --- CHANGELOG: generate this version's section from commits and insert it above
# the most recent existing version (right after the header block). ---
SECTION="$(scripts/changelog-section.sh "$VERSION")"
tmp="$(mktemp)"
SECTION="$SECTION" awk '
    !done && /^## \[/ {
        print ENVIRON["SECTION"]
        print ""
        done = 1
    }
    { print }
    END { if (!done) { print ""; print ENVIRON["SECTION"] } }
' "$CHANGELOG" > "$tmp"
mv "$tmp" "$CHANGELOG"

echo "Applied version $VERSION (build $BUILD_NUMBER) to Info.plist and CHANGELOG.md."
