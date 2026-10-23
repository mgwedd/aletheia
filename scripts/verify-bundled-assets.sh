#!/usr/bin/env bash
# Verifies the SHA-256 of every binary model/asset tracked in the repo against
# the pins below. A tracked .bin/.gguf/Core ML file that has no pin, a pinned
# file that is missing, or any digest mismatch fails.
#
# To change a bundled asset: replace the file, then update its pin here in the
# same commit (`shasum -a 256 <file>`).
#
# Usage:
#   scripts/verify-bundled-assets.sh              verify the repo
#   scripts/verify-bundled-assets.sh --self-test  tampered-fixture checks

set -uo pipefail

# "<path>  <sha256>" pins.
PINS='Sources/WhisperEngine/ggml-silero-v6.2.0.bin  2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987'
# Tracked files treated as bundled binary assets.
ASSET_RE='\.(bin|gguf|onnx|mlmodel[a-z]*|mlpackage|metallib)$'

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# verify <root> <pins>; prints problems to stderr, returns 1 on any.
verify() {
  local root="$1" pins="$2" bad=0 path want got tracked
  while read -r path want; do
    [ -n "$path" ] || continue
    if [ ! -f "$root/$path" ]; then
      echo "FAIL: pinned asset missing: $path" >&2; bad=1; continue
    fi
    got=$(sha256_of "$root/$path")
    if [ "$got" != "$want" ]; then
      echo "FAIL: $path sha256 ${got} != pinned ${want}" >&2; bad=1
    else
      echo "ok   $path ${got}"
    fi
  done <<PINLIST
$pins
PINLIST
  tracked=$(git -C "$root" ls-files | grep -iE "$ASSET_RE" || true)
  for path in $tracked; do
    printf '%s\n' "$pins" | awk -v p="$path" '$1 == p {f=1} END {exit !f}' \
      || { echo "FAIL: tracked binary asset has no pin: $path" >&2; bad=1; }
  done
  return $bad
}

self_test() {
  local d rc=0 good
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  git -C "$d" init -q
  printf 'fixture-model-bytes' >"$d/m.bin"
  git -C "$d" add m.bin
  good=$(sha256_of "$d/m.bin")
  verify "$d" "m.bin  $good" >/dev/null 2>&1 || { echo "FAIL - intact fixture should pass" >&2; rc=1; }
  printf 'x' >>"$d/m.bin"
  if verify "$d" "m.bin  $good" >/dev/null 2>&1; then echo "FAIL - tampered fixture should fail" >&2; rc=1; fi
  printf 'fixture-model-bytes' >"$d/m.bin"
  printf 'new' >"$d/extra.gguf"; git -C "$d" add extra.gguf
  if verify "$d" "m.bin  $good" >/dev/null 2>&1; then echo "FAIL - unpinned asset should fail" >&2; rc=1; fi
  if verify "$d" "gone.bin  $good" >/dev/null 2>&1; then echo "FAIL - missing asset should fail" >&2; rc=1; fi
  [ "$rc" -eq 0 ] && echo "self-test passed"
  return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") cd "$(dirname "$0")/.." && verify . "$PINS"; exit $? ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
