#!/bin/bash
# Builds Session Notes.app from source. Run this on a Mac with Xcode
# installed (the free Command Line Tools are not enough — SwiftUI/
# ScreenCaptureKit apps need the full Xcode app from the App Store).
#
# What this does:
#   1. Installs XcodeGen (via Homebrew) if it's missing.
#   2. Generates SessionNotes.xcodeproj from project.yml.
#   3. Builds a Release build, ad-hoc code signed with the Hardened Runtime
#      enabled (no Apple Developer account needed).
#   4. Copies the finished app to ./dist/Session Notes.app.
#
# First launch on any Mac will still need a right-click > Open, since this
# isn't notarized by Apple — see docs/SETUP-GUIDE.md.

set -euo pipefail
cd "$(dirname "$0")/../SessionNotes"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "XcodeGen not found — installing via Homebrew…"
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install XcodeGen. Install it from https://brew.sh, then re-run this script." >&2
        exit 1
    fi
    brew install xcodegen
fi

echo "Generating Xcode project…"
xcodegen generate

echo "Building (Release)…"
# Signing identity defaults to ad-hoc ("-"); the release workflow overrides it
# with a Developer ID when signing/notarizing (CODE_SIGN_IDENTITY env), and can
# add a secure timestamp via OTHER_CODE_SIGN_FLAGS="--timestamp".
IDENTITY="${CODE_SIGN_IDENTITY:--}"
EXTRA_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS:-}"

# -skipPackagePluginValidation keeps the build non-interactive: without it,
# xcodebuild can block on a "trust this package plugin?" prompt on a fresh
# machine (or in CI), which never gets answered.
xcodebuild \
    -project SessionNotes.xcodeproj \
    -scheme SessionNotes \
    -configuration Release \
    -derivedDataPath build \
    -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    OTHER_CODE_SIGN_FLAGS="$EXTRA_CODE_SIGN_FLAGS" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build

# The product/target name is "SessionNotes" (no space); the space only appears
# in the Finder display name (CFBundleDisplayName). So the built bundle is
# SessionNotes.app — we copy it to the friendlier "Session Notes.app" for dist.
APP_PATH="build/Build/Products/Release/SessionNotes.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build finished but the .app wasn't found at $APP_PATH" >&2
    exit 1
fi

mkdir -p ../dist
rm -rf "../dist/Session Notes.app"
cp -R "$APP_PATH" "../dist/Session Notes.app"

echo
echo "Done. Session Notes.app is in the dist/ folder at the repo root."
echo "First launch: right-click the app > Open, since it isn't notarized."
