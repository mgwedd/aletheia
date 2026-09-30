#!/usr/bin/env bash
# Verifies the SHA-256 pins baked into the app for downloadable Whisper models.
#
# Every model must be pinned (non-optional in Swift) AND the pin must be
# confirmed by independent readings, so a wrong or stale pin can never ship:
#
#   1. the pin in Sources/App/Services/WhisperModelPins.swift
#   2. sha256 of the bytes actually served at the pinned Hugging Face revision
#   3. the LFS oid (== sha256) the Hugging Face tree API reports for that revision
#   4. sha1 of the same bytes vs the SHA-1 published in whisper.cpp's models/README.md
#
# Any disagreement, missing value, or unexpected shape of the Swift source fails.
#
# Usage:
#   scripts/verify-model-pins.sh           verify the pins in the Swift source
#   scripts/verify-model-pins.sh --print   bootstrap: use the CURRENT Hugging Face
#                                          revision and print what to pin (still
#                                          fails on any cross-source disagreement)
#
# Needs curl and sha256sum/shasum + sha1sum/shasum. Downloads ~5 GB in total, so
# it is meant for CI (see .github/workflows/verify-model-pins.yml), not every build.

set -uo pipefail
cd "$(dirname "$0")/.."

PINS_FILE="Sources/App/Services/WhisperModelPins.swift"
SETTINGS_FILE="Sources/App/Services/AppSettings.swift"
HF_REPO="ggerganov/whisper.cpp"
README_URL="https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/models/README.md"
# "<Swift case>|<raw value>" pairs; must mirror `enum WhisperModel` exactly
# (checked below, so adding a case without updating this script fails).
WHISPER_MODELS="baseEn|base.en smallEn|small.en mediumEn|medium.en largeV3|large-v3"
EXPECTED_COUNT=4
# The one exact line that builds the download URL from the pinned revision.
DOWNLOAD_URL_LINE='        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/ggml-\(rawValue).bin")!'

FAILURES=0
MODE="verify"

die() { echo "ERROR: $*" >&2; exit 1; }
fail() { echo "FAIL: $*" >&2; FAILURES=$((FAILURES + 1)); }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"; fi; }

hash_of() { # algo(1|256) file
  local algo="$1" file="$2"
  if command -v "sha${algo}sum" >/dev/null 2>&1; then
    "sha${algo}sum" "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a "$algo" "$file" | awk '{print $1}'
  else
    die "need sha${algo}sum or shasum"
  fi
}

fetch() { # url outfile
  curl --fail --location --silent --show-error \
    --retry 3 --retry-all-errors --retry-delay 5 --connect-timeout 30 \
    -o "$2" "$1"
}

# ---- Swift source extraction (strict; anything unexpected is fatal) ---------

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

extract_revision() {
  local lines
  lines=$(grep -E '^    static let revision = ' "$PINS_FILE" || true)
  [ "$(count_lines "$lines")" -eq 1 ] || die "expected exactly one 'static let revision' line in $PINS_FILE"
  local rev
  rev=$(printf '%s\n' "$lines" | sed -nE 's/^    static let revision = "([0-9a-f]{40})"$/\1/p')
  [ -n "$rev" ] || die "revision in $PINS_FILE is not a 40-char lowercase hex commit sha"
  printf '%s\n' "$rev"
}

# Prints "<case> <sha256>" lines, one per pin. Fails unless the expectedSHA256
# switch consists solely of the strict `case .x: return "<64 hex>"` lines and
# there is exactly one per expected model with all-distinct digests.
extract_pins() {
  local block bad pins n
  block=$(awk '
    /^    var expectedSHA256: String \{$/ { inblk = 1; next }
    inblk && /^    \}$/ { inblk = 0 }
    inblk { print }
  ' "$PINS_FILE")
  [ -n "$block" ] || die "no 'var expectedSHA256: String' block (non-optional) found in $PINS_FILE"
  bad=$(printf '%s\n' "$block" | grep -vE '^        switch self \{$|^        \}$|^        case \.[A-Za-z0-9]+: return "[0-9a-f]{64}"$' || true)
  [ -z "$bad" ] || die "unexpected line(s) in expectedSHA256 (no nil/default/optional/uppercase allowed): $bad"
  pins=$(printf '%s\n' "$block" | sed -nE 's/^        case \.([A-Za-z0-9]+): return "([0-9a-f]{64})"$/\1 \2/p')
  n=$(count_lines "$pins")
  [ "$n" -eq "$EXPECTED_COUNT" ] || die "expected exactly $EXPECTED_COUNT pins in $PINS_FILE, found $n"
  local pair c
  for pair in $WHISPER_MODELS; do
    c=$(printf '%s\n' "$pins" | awk -v k="${pair%%|*}" '$1 == k' | grep -c . || true)
    [ "$c" -eq 1 ] || die "expected exactly one pin for ${pair%%|*}, found $c"
  done
  [ -z "$(printf '%s\n' "$pins" | awk '{print $2}' | sort | uniq -d)" ] || die "two models share the same pin"
  printf '%s\n' "$pins"
}

check_swift_shape() {
  # The script's model table must match the enum exactly.
  local cases pair
  cases=$(awk '/^enum WhisperModel/ { i = 1; next } i && /^}/ { i = 0 } i && /^    case /' "$SETTINGS_FILE")
  [ "$(count_lines "$cases")" -eq "$EXPECTED_COUNT" ] || die "enum WhisperModel in $SETTINGS_FILE has a different case count than this script's table"
  for pair in $WHISPER_MODELS; do
    printf '%s\n' "$cases" | grep -qxF "    case ${pair%%|*} = \"${pair##*|}\"" \
      || die "enum WhisperModel is missing: case ${pair%%|*} = \"${pair##*|}\""
  done
  grep -qxF -- "$DOWNLOAD_URL_LINE" "$PINS_FILE" \
    || die "downloadURL in $PINS_FILE must be exactly the revision-pinned resolve/\\(Self.revision) URL (not resolve/main)"
  [ "$(grep -c 'resolve/' "$PINS_FILE" || true)" -eq 1 ] || die "unexpected extra resolve/ URL in $PINS_FILE"
}

# ---- remote readings --------------------------------------------------------

# LFS oid (sha256) of a file from the tree-API JSON; prints nothing if absent.
lfs_oid_for() { # tree_json file
  printf '%s' "$1" \
    | sed 's/{"type":/\
{"type":/g' \
    | grep -F "\"path\":\"$2\"" \
    | sed -nE 's/.*"lfs":\{"oid":"([0-9a-f]{64})".*/\1/p'
}

# SHA-1 published in the whisper.cpp README table row for a model.
readme_sha1_for() { # readme_text raw_name
  local esc
  esc=$(printf '%s' "$2" | sed 's/[.[\*^$]/\\&/g')
  printf '%s\n' "$1" \
    | grep -E "^\|[[:space:]]*${esc}[[:space:]]*\|" \
    | grep -oE '[0-9a-f]{40}'
}

# ---- per-model check --------------------------------------------------------

check_model() { # case raw pin(optional; verify mode)
  local case_name="$1" raw="$2" pin="${3:-}"
  local file="ggml-${raw}.bin"
  local url="https://huggingface.co/${HF_REPO}/resolve/${REVISION}/${file}"
  local tmp="${WORK}/${file}"
  # Never let an empty extraction turn into a vacuous pass: in verify mode a
  # model without a pin from the Swift source is a failure.
  if [ "$MODE" = "verify" ] && [ -z "$pin" ]; then
    fail "${raw}: no pin found in ${PINS_FILE}"
    return
  fi
  echo "==> ${raw}: downloading ${url}"
  if ! fetch "$url" "$tmp"; then
    fail "${raw}: download failed"
    return
  fi
  local dl256 dl1 size lfs readme1 lfs_n readme_n
  dl256=$(hash_of 256 "$tmp"); dl1=$(hash_of 1 "$tmp"); size=$(wc -c <"$tmp" | tr -d ' ')
  rm -f "$tmp"
  lfs=$(lfs_oid_for "$TREE_JSON" "$file"); lfs_n=$(count_lines "$lfs")
  readme1=$(readme_sha1_for "$README" "$raw"); readme_n=$(count_lines "$readme1")

  echo "    size            ${size} bytes"
  echo "    sha256 (bytes)  ${dl256}"
  echo "    sha256 (HF LFS) ${lfs:-<missing>}"
  echo "    sha1   (bytes)  ${dl1}"
  echo "    sha1   (README) ${readme1:-<missing>}"
  [ -z "$pin" ] || echo "    sha256 (pin)    ${pin}"
  summary "| \`${raw}\` | \`${dl256}\` | \`${lfs:-missing}\` | \`${dl1}\` | \`${readme1:-missing}\` |"
  echo "PIN|${case_name}|${raw}|${dl256}"

  [ "$lfs_n" -eq 1 ] || { fail "${raw}: expected exactly 1 LFS oid from the HF tree API, got ${lfs_n}"; return; }
  [ "$readme_n" -eq 1 ] || { fail "${raw}: expected exactly 1 SHA-1 row in the whisper.cpp README, got ${readme_n}"; return; }
  [ "$dl256" = "$lfs" ] || fail "${raw}: sha256 of downloaded bytes (${dl256}) != HF LFS oid (${lfs})"
  [ "$dl1" = "$readme1" ] || fail "${raw}: sha1 of downloaded bytes (${dl1}) != whisper.cpp README (${readme1})"
  if [ -n "$pin" ] && [ "$dl256" != "$pin" ]; then
    fail "${raw}: pin in ${PINS_FILE} (${pin}) != sha256 of bytes at revision (${dl256})"
  fi
  return 0
}

# ---- main -------------------------------------------------------------------

main() {
  case "${1:-}" in
    "") MODE="verify" ;;
    --print) MODE="print" ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (use --print or no arguments)" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is required"

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  local pins=""
  if [ "$MODE" = "verify" ]; then
    check_swift_shape
    REVISION=$(extract_revision) || exit 1
    pins=$(extract_pins) || exit 1
  else
    local info
    info=$(curl --fail --location --silent --show-error --retry 3 --retry-all-errors "https://huggingface.co/api/models/${HF_REPO}") \
      || die "could not fetch the Hugging Face model info"
    REVISION=$(printf '%s' "$info" | grep -oE '"sha":"[0-9a-f]{40}"' | head -1 | sed -E 's/.*"([0-9a-f]{40})"/\1/')
    [ -n "$REVISION" ] || die "no commit sha in the Hugging Face model info"
  fi
  echo "Revision: ${REVISION} (mode: ${MODE})"

  TREE_JSON=$(curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
    "https://huggingface.co/api/models/${HF_REPO}/tree/${REVISION}") \
    || die "revision ${REVISION} does not resolve on Hugging Face (tree API failed)"
  README=$(curl --fail --location --silent --show-error --retry 3 --retry-all-errors "$README_URL") \
    || die "could not fetch the whisper.cpp README from ${README_URL}"

  summary "### Whisper model pins (${MODE}) at \`${REVISION}\`"
  summary ""
  summary "| model | sha256 (bytes) | sha256 (HF LFS) | sha1 (bytes) | sha1 (README) |"
  summary "|---|---|---|---|---|"

  local pair case_name raw pin
  for pair in $WHISPER_MODELS; do
    case_name="${pair%%|*}"; raw="${pair##*|}"; pin=""
    if [ "$MODE" = "verify" ]; then
      pin=$(printf '%s\n' "$pins" | awk -v k="$case_name" '$1 == k {print $2}')
    fi
    check_model "$case_name" "$raw" "$pin"
  done
  echo "REVISION|${REVISION}"

  if [ "$FAILURES" -gt 0 ]; then
    summary ""
    summary "**${FAILURES} check(s) FAILED** - see the log."
    echo "${FAILURES} check(s) failed." >&2
    exit 1
  fi
  echo "All sources agree for all ${EXPECTED_COUNT} models at ${REVISION}."
  summary ""
  summary "All sources agree for all ${EXPECTED_COUNT} models."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
