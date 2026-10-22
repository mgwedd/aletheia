#!/bin/bash
# Builds Aletheia.app from source. Run this on a Mac with Xcode
# installed (the free Command Line Tools are not enough — SwiftUI/
# ScreenCaptureKit apps need the full Xcode app from the App Store).
#
# What this does:
#   1. Installs XcodeGen (via Homebrew) if it's missing.
#   2. Generates Aletheia.xcodeproj from project.yml.
#   3. Builds a Release build with the Hardened Runtime enabled, ad-hoc code
#      signed (no Apple Developer account needed). Set CODE_SIGN_IDENTITY to
#      re-sign the finished app with a Developer ID; release.yml does this
#      when the signing secrets are configured.
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
# xcodebuild always signs ad-hoc. Passing a Developer ID here also applies it
# to the framework targets, which are automatically signed and fail
# with "conflicting provisioning settings". A Developer ID (CODE_SIGN_IDENTITY
# env) is applied to the finished app below instead; OTHER_CODE_SIGN_FLAGS can
# add a secure timestamp ("--timestamp").
#
# No Hardened Runtime at this stage: its library validation refuses to load
# ad-hoc-signed frameworks (no Team ID) even into an ad-hoc app, so an ad-hoc
# build with it dies at launch. The Developer ID signing below adds it
# (`--options runtime`) to the app and every framework.
IDENTITY="${CODE_SIGN_IDENTITY:--}"
EXTRA_CODE_SIGN_FLAGS="${OTHER_CODE_SIGN_FLAGS:-}"

# -skipPackagePluginValidation keeps the build non-interactive: without it,
# xcodebuild can block on a "trust this package plugin?" prompt on a fresh
# machine (or in CI), which never gets answered.
xcodebuild \
    -project Aletheia.xcodeproj \
    -scheme Aletheia \
    -configuration Release \
    -derivedDataPath build \
    -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY="-" \
    ENABLE_HARDENED_RUNTIME=NO \
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

if [ "$IDENTITY" != "-" ]; then
    echo "Signing with ${IDENTITY}…"
    # Embedded frameworks (whisper, WhisperEngine) first: re-signing the app
    # doesn't touch them, and ad-hoc nested code fails notarization and, under
    # the hardened runtime, library validation at launch.
    for framework in dist/Aletheia.app/Contents/Frameworks/*.framework; do
        [ -e "$framework" ] || continue
        # shellcheck disable=SC2086
        codesign --force --options runtime $EXTRA_CODE_SIGN_FLAGS \
            --sign "$IDENTITY" "$framework"
    done
    # The network helper (an XPC service inside the app) is signed with its
    # OWN entitlements (sandbox + network only), before the app that contains
    # it. Signing the app afterwards seals the helper's signature into it.
    for helper in dist/Aletheia.app/Contents/XPCServices/*.xpc; do
        [ -e "$helper" ] || continue
        # shellcheck disable=SC2086
        codesign --force --options runtime $EXTRA_CODE_SIGN_FLAGS \
            --entitlements Sources/NetworkHelper/NetworkHelper.entitlements \
            --sign "$IDENTITY" "$helper"
    done
    # Explicit entitlements, not --preserve-metadata: a plain `xcodebuild build`
    # injects get-task-allow, which Apple's notary service rejects.
    # shellcheck disable=SC2086
    codesign --force --options runtime $EXTRA_CODE_SIGN_FLAGS \
        --entitlements Sources/App/Resources/Aletheia.entitlements \
        --sign "$IDENTITY" "dist/Aletheia.app"
    codesign --verify --strict "dist/Aletheia.app"
fi

echo
echo "Done. Aletheia.app is in the dist/ folder at the repo root."
if [ "$IDENTITY" = "-" ]; then
    echo "First launch: right-click the app > Open, since it isn't notarized."
fi
