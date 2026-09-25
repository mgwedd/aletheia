#!/bin/bash
# One-command Mac bring-up check for the embedded llama.cpp engine
# (Sources/App/Services/Llama/LlamaEngine.swift, LlamaAssistant.swift): it
# temporarily enables the staged `llama` package in project.yml, generates
# and builds a Release build so every `llama.h` call in those two files is
# compiler-verified against the pinned b11149 revision, then reverts
# project.yml to exactly what's committed either way (pass or fail) — this
# script verifies the bring-up, it does not commit the package enablement
# itself. See README › Embedded llama.cpp.
#
#   ./scripts/verify-llama-bringup.sh
#
# Requires the same Mac/Xcode setup as scripts/build.sh. Idempotent and safe
# to re-run: it always starts from project.yml's committed state and always
# puts it back before exiting.

set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT_YML="project.yml"

# --- The four staged lines we flip on, verbatim as committed today. If this
# script ever fails to find them, project.yml's staging comment moved — update
# these to match rather than guessing with a looser pattern. ---
OLD_PACKAGE_HEADER='  # llama:'
NEW_PACKAGE_HEADER='  llama:'
OLD_PACKAGE_URL='  #   url: https://github.com/ggml-org/llama.cpp.git'
NEW_PACKAGE_URL='    url: https://github.com/ggml-org/llama.cpp.git'
OLD_PACKAGE_REVISION='  #   revision: "d2e54583c7452353eb35d40431281f6ee984332f"  # tag b11149'
NEW_PACKAGE_REVISION='    revision: "d2e54583c7452353eb35d40431281f6ee984332f"  # tag b11149'
OLD_TARGET_DEP='      # - package: llama   # staged: uncomment with the packages stanza above'
NEW_TARGET_DEP='      - package: llama'

BACKUP="$(mktemp -t aletheia-project-yml.XXXXXX)"
cp "$PROJECT_YML" "$BACKUP"

cleanup() {
    local status=$?
    cp "$BACKUP" "$PROJECT_YML"
    rm -f "$BACKUP"
    echo
    if [ "$status" -eq 0 ]; then
        echo "PASS — LlamaEngine.swift and LlamaAssistant.swift compiled clean against"
        echo "       the pinned llama.cpp b11149 revision."
        echo "project.yml has been reverted to its committed (staged) state."
        echo
        echo "Next: uncomment the same two spots in project.yml yourself, commit that"
        echo "alongside whatever prompted this bring-up, and open a PR."
    else
        echo "FAIL (exit $status) — see the build output above."
        echo "project.yml has been reverted to its committed (staged) state regardless."
    fi
    exit "$status"
}
trap cleanup EXIT

echo "Enabling the staged llama package in $PROJECT_YML…"
awk -v old1="$OLD_PACKAGE_HEADER" -v new1="$NEW_PACKAGE_HEADER" \
    -v old2="$OLD_PACKAGE_URL" -v new2="$NEW_PACKAGE_URL" \
    -v old3="$OLD_PACKAGE_REVISION" -v new3="$NEW_PACKAGE_REVISION" \
    -v old4="$OLD_TARGET_DEP" -v new4="$NEW_TARGET_DEP" '
    $0 == old1 { print new1; next }
    $0 == old2 { print new2; next }
    $0 == old3 { print new3; next }
    $0 == old4 { print new4; next }
    { print }
' "$PROJECT_YML" > "$PROJECT_YML.tmp"
mv "$PROJECT_YML.tmp" "$PROJECT_YML"

if ! grep -qFx "$NEW_PACKAGE_HEADER" "$PROJECT_YML" \
    || ! grep -qFx "$NEW_PACKAGE_URL" "$PROJECT_YML" \
    || ! grep -qFx "$NEW_PACKAGE_REVISION" "$PROJECT_YML" \
    || ! grep -qFx "$NEW_TARGET_DEP" "$PROJECT_YML"; then
    echo "Error: couldn't find the staged llama package stanza to uncomment in $PROJECT_YML." >&2
    echo "It may have moved or been reworded — update this script's OLD_* lines to match." >&2
    exit 1
fi

echo "project.yml now links llama.cpp:"
grep -n "llama" "$PROJECT_YML" | sed 's/^/  /'
echo

# Preflight: the full Xcode app is required (mirrors scripts/build.sh).
if ! xcodebuild -version >/dev/null 2>&1; then
    DEVDIR="$(xcode-select -p 2>/dev/null || echo 'none')"
    echo "Error: xcodebuild needs the full Xcode app, but the active developer directory is:" >&2
    echo "    $DEVDIR" >&2
    echo >&2
    echo "Fix it (install Xcode from the App Store first if you haven't):" >&2
    echo "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    echo "    sudo xcodebuild -license accept" >&2
    exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen not found — installing via Homebrew…"
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install XcodeGen. Install it from https://brew.sh, then re-run this script." >&2
        exit 1
    fi
    brew install xcodegen
fi

echo "Generating Xcode project (llama linked)…"
xcodegen generate

echo "Building (Release) — this is the first real compile of every llama.h call"
echo "in LlamaEngine.swift and LlamaAssistant.swift…"
xcodebuild \
    -project Aletheia.xcodeproj \
    -scheme Aletheia \
    -configuration Release \
    -derivedDataPath build \
    -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build
