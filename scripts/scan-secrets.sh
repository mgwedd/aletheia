#!/bin/bash
# Fails if a secret, credential, or PHI artifact has been committed. This is the
# leak-prevention gate: it runs in CI on every PR/push (secret-scan.yml) and can
# also run as a local pre-commit hook (scripts/hooks/pre-commit).
#
# First-party only — pure git + grep, no third-party scanner — matching the
# project's supply-chain stance. It complements GitHub's native secret scanning
# / push protection (recommended on in Settings for the public repo); this gate
# also catches PHI artifacts and files GitHub's scanner doesn't know about.
#
# Scans the whole tracked tree. Exit 0 = clean, 1 = a likely leak was found
# (printed with file:line).

set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0

# --- 1. Secret CONTENT patterns (specific enough to avoid false positives) ---
# The scanner itself and Markdown docs are excluded — they describe these
# patterns without containing real secrets.
CONTENT_PATTERNS='-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN OPENSSH PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}|sk-[A-Za-z0-9]{32,}'

# `-e` is required: the patterns start with `-----BEGIN`, which git grep would
# otherwise parse as an option. rc 0 = matches found, 1 = none, >1 = real error
# (which must fail loudly, never be mistaken for "clean").
CONTENT_HITS="$(git grep -nIE -e "$CONTENT_PATTERNS" -- \
    ':(exclude)scripts/scan-secrets.sh' \
    ':(exclude)scripts/hooks/pre-commit' \
    ':(exclude)*.md' 2>/dev/null)"
GREP_RC=$?
if [ "$GREP_RC" -gt 1 ]; then
    echo "❌ Scanner error (git grep exited $GREP_RC); failing closed."
    exit 2
fi
if [ -n "$CONTENT_HITS" ]; then
    echo "❌ Possible secret content committed:"
    echo "$CONTENT_HITS"
    echo
    FAIL=1
fi

# --- 2. Sensitive / PHI FILENAMES that must never be committed ---
# Credentials & keys, plus this app's PHI runtime artifacts (audio, transcripts,
# summaries, the annotations DB, patient/chat JSON) — those live only in the
# user's data folder, never in git.
FILENAME_PATTERN='(\.p12|\.pfx|\.pem|\.key|\.p8|\.cer|\.mobileprovision|\.keychain[a-z-]*|\.env|\.env\..*|id_rsa|id_dsa|\.caf|\.wav|\.sqlite[0-9]?|transcript\.txt|summary\.txt|patient\.json|patient_chat\.json|chat\.json)$'

FILES="$(git ls-files)"
NAME_HITS="$(printf '%s\n' "$FILES" | grep -iE "$FILENAME_PATTERN" || true)"
if [ -n "$NAME_HITS" ]; then
    echo "❌ Sensitive/PHI files must not be committed:"
    echo "$NAME_HITS"
    echo
    FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
    echo "✅ No secrets or PHI artifacts found in the tracked tree."
fi
exit "$FAIL"
