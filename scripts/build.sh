#!/bin/bash
# Builds Aletheia.app from source. Run this on a Mac with Xcode
# installed (the free Command Line Tools are not enough — SwiftUI/
# ScreenCaptureKit apps need the full Xcode app from the App Store).
#
# What this does:
#   1. Installs XcodeGen (via Homebrew) if it's missing.
#   2. Generates Aletheia.xcodeproj from project.yml.
#   3. Builds a Release build with the Hardened Runtime enabled, ad-hoc code
#      signed by default (no Apple Developer account needed). Set
#      CODE_SIGN_IDENTITY (and DEVELOPMENT_TEAM) to sign with a Developer ID;
#      release.yml does this when the signing secrets are configured.
#   4. Copies the finished app to ./dist/Aletheia.app.
#
# An ad-hoc build isn't notarized by Apple, so first launch on any Mac needs a
# right-click > Open — see docs/SETUP-GUIDE.md.

set -euo pipefail
cd "$(dirname "$0")/.."

# Preflight: the full Xcode app is required. If the active developer directory
# points at the Command Line Tools (or Xcode isn't installed), xcodebuild fails
# deep in the build with a cryptic message — catch it here with the fix.
if ! xcodebuild -version >/dev/null 2>&1; then
    DEVDIR="$(xcode-select -p 2>/dev/null || echo 'none')"
    echo "Error: xcodebuild needs the full Xcode app, but the active developer directory is:" >&2
    echo "    $DEVDIR" >&2
    echo >&2
    echo "Fix it (install Xcode from the App Store first if you haven't):" >&2
    echo "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer" >&2
    echo "    sudo xcodebuild -license accept" >&2
    echo "Then re-run this script. Verify with: xcodebuild -version" >&2
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

echo "Generating Xcode project…"
xcodegen generate

echo "Building (Release)…"
# Signing identity defaults to ad-hoc ("-"); the release workflow overrides it
# with a Developer ID when signing/notarizing (CODE_SIGN_IDENTITY env), and can
# add a secure timestamp via OTHER_CODE_SIGN_FLAGS="--timestamp".
IDENTITY="${CODE_SIGN_IDENTITY:--}"
EXTRA_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS:-}"
TEAM="${DEVELOPMENT_TEAM:-}"

# -skipPackagePluginValidation keeps the build non-interactive: without it,
# xcodebuild can block on a "trust this package plugin?" prompt on a fresh
# machine (or in CI), which never gets answered.
xcodebuild \
    -project Aletheia.xcodeproj \
    -scheme Aletheia \
    -configuration Release \
    -derivedDataPath build \
    -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS="$EXTRA_CODE_SIGN_FLAGS" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build

APP_PATH="build/Build/Products/Release/Aletheia.app"
if [ ! -d "$APP_PATH" ]; then
    echo "Build finished but the .app wasn't found at $APP_PATH" >&2
    exit 1
fi

mkdir -p dist
rm -rf "dist/Aletheia.app"
cp -R "$APP_PATH" "dist/Aletheia.app"

echo
echo "Done. Aletheia.app is in the dist/ folder at the repo root."
if [ "$IDENTITY" = "-" ]; then
    echo "First launch: right-click the app > Open, since it isn't notarized."
fi
