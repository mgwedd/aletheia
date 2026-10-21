#!/usr/bin/env bash
# Prints the CHANGELOG.md entry for one version, for the GitHub release body
# and the appcast's releaseNotes. Auto Release writes that entry (from
# changelog-section.sh) in the tagged commit, so the tag already carries it.
#
# Prints everything under "## [<version>]" up to the next "## [" heading,
# without the heading itself and without leading or trailing blank lines.
# Prints "Maintenance release." when the version has no entry or an empty one
# (a release of only chore/docs/ci commits).
#
# Usage: scripts/release-notes.sh <version> [changelog]   (default CHANGELOG.md)

set -euo pipefail

VERSION="${1:?usage: release-notes.sh <version> [changelog]}"
VERSION="${VERSION#v}"
FILE="${2:-$(dirname "$0")/../CHANGELOG.md}"

NOTES="$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { on = 1; next }
    on && /^## \[/ { exit }
    on { print }
' "$FILE" | sed -e '/./,$!d' | sed -e ':a' -e '/^\n*$/{$d;N;ba' -e '}')"

if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "Maintenance release."
else
    printf '%s\n' "$NOTES"
fi
