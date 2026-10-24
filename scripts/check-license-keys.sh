#!/usr/bin/env bash
# Release-time guard: the production license keyring must not be empty.
#
# A production build with no public keys rejects every license, so shipping it would lock
# every user out. This reads the block between the BEGIN/END PRODUCTION KEYS markers in
# LicenseKeyring.swift and fails unless it holds at least one `"<kid>": "<key>"` entry,
# where <key> is a 44-character base64 string (a raw 32-byte Ed25519 public key).
#
#   scripts/check-license-keys.sh              check the real file
#   scripts/check-license-keys.sh --self-test  exercise the checker on sample input
set -euo pipefail

FILE="Sources/App/Services/License/LicenseKeyring.swift"
ENTRY='^[[:space:]]*"[A-Za-z0-9._-]+"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/]{43}="[[:space:]]*,?[[:space:]]*$'

# The dev key id and public key, read from their definitions in the same file.
dev_value() { sed -n "s/.*static let $2 = \"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

block() {
  # Prints the non-comment lines inside the marked block of $1.
  awk '/\/\/ BEGIN PRODUCTION KEYS/{on=1;next} /\/\/ END PRODUCTION KEYS/{on=0} on' "$1" \
    | grep -v '^[[:space:]]*//' || true
}

count_keys() {
  # Prints the number of well-formed key entries in the marked block of $1.
  block "$1" | grep -Ec "$ENTRY" || true
}

check() {
  local file="$1"
  if [ ! -f "$file" ]; then echo "::error::$file not found" >&2; return 1; fi
  if ! grep -q '// BEGIN PRODUCTION KEYS' "$file" || ! grep -q '// END PRODUCTION KEYS' "$file"; then
    echo "::error::$file is missing the BEGIN/END PRODUCTION KEYS markers" >&2; return 1
  fi
  local n; n="$(count_keys "$file")"
  local dev_kid dev_key
  dev_kid="$(dev_value "$file" devKeyID)"; dev_key="$(dev_value "$file" devPublicKey)"
  if [ -z "$dev_kid" ] || [ -z "$dev_key" ]; then
    echo "::error::$file no longer defines devKeyID and devPublicKey" >&2; return 1
  fi
  if block "$file" | grep -Fq -e "$dev_kid" -e "$dev_key"; then
    echo "::error::The production license keyring in $file contains the dev key. Remove it before releasing." >&2
    return 1
  fi
  if [ "${n:-0}" -lt 1 ]; then
    echo "::error::The production license keyring in $file is empty. Add the production public keys before releasing." >&2
    return 1
  fi
  echo "Production license keyring holds $n key(s)."
}

if [ "${1:-}" = "--self-test" ]; then
  T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
  # Placeholder keys: right shape, no real key material.
  KEY="$(printf 'B%.0s' $(seq 43))="
  DEV_KID="dev-x"; DEV_KEY="$(printf 'A%.0s' $(seq 43))="; OTHER="$(printf 'C%.0s' $(seq 43))="
  mk() {
    printf '    static let devKeyID = "%s"\n    static let devPublicKey = "%s"\n' "$DEV_KID" "$DEV_KEY" > "$T/f.swift"
    printf '    // BEGIN PRODUCTION KEYS (x)\n%s\n    // END PRODUCTION KEYS\n' "$1" >> "$T/f.swift"
  }
  mk '    static let productionPublicKeys: [String: String] = [:]'
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: empty keyring passed"; exit 1; fi
  mk "    // \"commented\": \"$KEY\","; 
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: commented key passed"; exit 1; fi
  mk '    static let k: [String: String] = ["prod-1": "tooshort"]'
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: malformed key passed"; exit 1; fi
  mk "        \"$DEV_KID\": \"$OTHER\","
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: dev kid passed"; exit 1; fi
  mk "        \"prod-1\": \"$DEV_KEY\","
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: dev key passed"; exit 1; fi
  printf 'no markers\n' > "$T/f.swift"
  if check "$T/f.swift" >/dev/null 2>&1; then echo "self-test FAILED: missing markers passed"; exit 1; fi
  mk "        \"prod-2027\": \"$KEY\","
  check "$T/f.swift" >/dev/null || { echo "self-test FAILED: valid keyring rejected"; exit 1; }
  echo "check-license-keys self-test passed"
  exit 0
fi

check "$FILE"
