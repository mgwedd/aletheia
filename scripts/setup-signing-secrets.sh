#!/bin/bash
# Sets the repository secrets that .github/workflows/release.yml needs to ship a
# Developer ID-signed, notarized DMG. Run it on your Mac, once.
#
#   scripts/setup-signing-secrets.sh [owner/repo]
#
# The certificate, its password and your notarization password are read here and
# handed to `gh secret set` over stdin. They are never echoed or written to disk
# (the temporary keychain used to check the certificate is deleted). The local
# `security` and `notarytool` checks take the passwords as arguments for the
# moment they run, exactly as the release workflow does.
#
# Before running it you need:
#   1. A "Developer ID Application" certificate exported as a .p12:
#      Keychain Access -> My Certificates -> right-click "Developer ID
#      Application: ..." -> Export -> .p12, with a password of your choice.
#   2. An app-specific password for your Apple ID (account.apple.com ->
#      Sign-In and Security -> App-Specific Passwords).
#   3. The GitHub CLI, signed in with permission to edit this repo's secrets
#      (`gh auth login`).

set -euo pipefail

REPO="${1:-mgwedd/aletheia}"
KEYCHAIN=""

cleanup() {
    if [ -n "$KEYCHAIN" ] && [ -f "$KEYCHAIN" ]; then
        security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

die() { echo "Error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "run this on a Mac (it uses the macOS security and notarytool tools)."
command -v gh >/dev/null 2>&1 || die "the GitHub CLI is required: https://cli.github.com, then 'gh auth login'."
gh auth status >/dev/null 2>&1 || die "'gh' is not signed in. Run 'gh auth login' first."
command -v xcrun >/dev/null 2>&1 || die "Xcode command line tools are required for notarytool."

echo "Target repository: $REPO"
echo

# --- certificate --------------------------------------------------------------

read -r -p "Path to your Developer ID Application .p12: " P12_PATH
P12_PATH="${P12_PATH/#\~/$HOME}"
[ -f "$P12_PATH" ] || die "no file at $P12_PATH"

read -r -s -p ".p12 password: " P12_PASSWORD
echo
[ -n "$P12_PASSWORD" ] || die "the .p12 password can't be empty (the workflow imports it with -P)."

# Import into a throwaway keychain, the same way CI will, so a wrong password or
# the wrong kind of certificate fails here and not on the release runner.
KEYCHAIN="$(mktemp -d)/check.keychain-db"
CHECK_PASSWORD="$(openssl rand -base64 24)"
security create-keychain -p "$CHECK_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$CHECK_PASSWORD" "$KEYCHAIN"
security import "$P12_PATH" -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN" >/dev/null \
    || die "couldn't import the .p12. Check the password."

IDENTITIES="$(security find-identity -v -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' || true)"
if [ -z "$IDENTITIES" ]; then
    # -v hides identities whose chain it can't validate from this temporary
    # keychain. Look again without it and say so, rather than block on a
    # check the runner may not share.
    IDENTITIES="$(security find-identity -p codesigning "$KEYCHAIN" | grep 'Developer ID Application' || true)"
    [ -z "$IDENTITIES" ] || echo "Warning: couldn't validate the certificate chain locally. Continuing; the dry run is the real test."
fi
[ -n "$IDENTITIES" ] || die "no 'Developer ID Application' identity in that .p12. Export that certificate (not 'Apple Development' or 'Mac Installer')."

COUNT="$(echo "$IDENTITIES" | wc -l | tr -d ' ')"
if [ "$COUNT" -gt 1 ]; then
    echo "More than one Developer ID Application identity found:"
    echo "$IDENTITIES"
    die "export a .p12 that contains just one."
fi

SIGN_IDENTITY="$(echo "$IDENTITIES" | sed -E 's/^[^"]*"([^"]+)".*$/\1/')"
TEAM_ID="$(echo "$SIGN_IDENTITY" | sed -E 's/^.*\(([A-Z0-9]{10})\)$/\1/')"
[ "${#TEAM_ID}" -eq 10 ] || die "couldn't read a 10-character team ID from '$SIGN_IDENTITY'."

echo "Signing identity: $SIGN_IDENTITY"
echo "Team ID:          $TEAM_ID"
echo

# --- notarization credentials -------------------------------------------------

read -r -p "Apple ID email: " APPLE_ID
read -r -s -p "App-specific password: " APP_PASSWORD
echo
[ -n "$APPLE_ID" ] && [ -n "$APP_PASSWORD" ] || die "Apple ID and app-specific password are required."

echo "Checking notarization credentials with Apple..."
if xcrun notarytool history --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" >/dev/null 2>&1; then
    echo "Credentials accepted."
else
    die "Apple rejected the Apple ID, team ID or app-specific password. Nothing was set."
fi
echo

# --- set the secrets ----------------------------------------------------------

set_secret() {
    # Value comes in on stdin so it never reaches a command line.
    gh secret set "$1" --repo "$REPO" >/dev/null
    echo "  set $1"
}

echo "Setting secrets on $REPO:"
base64 < "$P12_PATH" | tr -d '\n' | set_secret MACOS_CERTIFICATE
printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERTIFICATE_PWD
printf '%s' "$SIGN_IDENTITY" | set_secret MACOS_SIGN_IDENTITY
openssl rand -base64 24 | tr -d '\n' | set_secret KEYCHAIN_PASSWORD
printf '%s' "$APPLE_ID" | set_secret APPLE_ID
printf '%s' "$TEAM_ID" | set_secret APPLE_TEAM_ID
printf '%s' "$APP_PASSWORD" | set_secret APPLE_APP_SPECIFIC_PASSWORD

echo
echo "Done. Prove it before tagging a release (nothing is published):"
echo "  gh workflow run release.yml --repo $REPO --ref main"
echo "  gh run watch --repo $REPO"
echo "The signed, notarized DMG is attached to that run as 'aletheia-dryrun-dmg'."
echo
echo "You can delete the .p12 from disk now if you don't need it."
