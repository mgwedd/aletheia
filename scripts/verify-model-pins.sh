#!/usr/bin/env bash
# Verifies the SHA-256 pins baked into the app for every downloadable model
# (Whisper ggml models and the embedded-llama GGUF models).
#
# Every model must be pinned (non-optional in Swift) AND the pin must be
# confirmed by independent readings, so a wrong or stale pin can never ship:
#
#   1. the pin (and Hugging Face commit) in the Swift source
#   2. sha256 of the bytes actually served at that pinned Hugging Face commit
#   3. the LFS oid (== sha256) the Hugging Face tree API reports for that commit
#   4. Whisper only: sha1 of the same bytes vs the SHA-1 published in
#      whisper.cpp's models/README.md (the GGUF repos publish no second digest)
#
# Any disagreement, missing value, or unexpected shape of the Swift source fails.
#
# Usage:
#   scripts/verify-model-pins.sh                 verify the pins in the Swift source
#   scripts/verify-model-pins.sh --print         bootstrap: use the CURRENT Hugging
#                                                Face commit of each repo and print what
#                                                to pin (still fails on any cross-source
#                                                disagreement)
#   scripts/verify-model-pins.sh --only whisper|llama   limit to one model family
#
# Needs curl and sha256sum/shasum + sha1sum/shasum. Downloads several GB in
# total, so it is meant for CI (see .github/workflows/verify-model-pins.yml),
# not every build.

set -uo pipefail
cd "$(dirname "$0")/.."

WHISPER_PINS_FILE="Sources/App/Services/WhisperModelPins.swift"
WHISPER_ENUM_FILE="Sources/App/Services/AppSettings.swift"
LLAMA_PINS_FILE="Sources/App/Services/Llama/LlamaModelPins.swift"
LLAMA_ENUM_FILE="Sources/App/Services/Llama/LlamaModel.swift"
README_URL="https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/models/README.md"

# Model tables: "<Swift case>|<enum raw value>|<HF repo>|<file in repo>", space separated.
# They must mirror the Swift enums exactly (checked below, so adding a case
# without updating this script fails).
WHISPER_MODELS="baseEn|base.en|ggerganov/whisper.cpp|ggml-base.en.bin smallEn|small.en|ggerganov/whisper.cpp|ggml-small.en.bin mediumEn|medium.en|ggerganov/whisper.cpp|ggml-medium.en.bin largeV3|large-v3|ggerganov/whisper.cpp|ggml-large-v3.bin"
LLAMA_MODELS="llama32_1b|llama-3.2-1b-instruct-q4_k_m|ggml-org/Llama-3.2-1B-Instruct-GGUF|llama-3.2-1b-instruct-q4_k_m.gguf llama32_3b|llama-3.2-3b-instruct-q4_k_m|ggml-org/Llama-3.2-3B-Instruct-GGUF|llama-3.2-3b-instruct-q4_k_m.gguf"
# The one exact line that builds a Whisper download URL from the pinned revision.
WHISPER_URL_LINE='        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(Self.revision)/ggml-\(rawValue).bin")!'

FAILURES=0
MODE="verify"
ONLY=""
README=""

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

fetch_text() { # url
  curl --fail --location --silent --show-error --retry 3 --retry-all-errors --retry-delay 5 "$1"
}

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

# ---- Swift source extraction (strict; anything unexpected is fatal) ---------

# Prints "<case> <value>" lines from `var <varname>: String { switch self {
# case .x: return "<hex>" ... } }` in <file>. Fails unless the block consists
# solely of strict `case .x: return "<lowercase hex of <hexlen> chars>"` lines
# with exactly one per row of <table> (no nil/default/optional/uppercase).
extract_switch() { # file varname hexlen table
  local file="$1" varname="$2" hexlen="$3" table="$4"
  local block bad values n row c expected
  expected=$(printf '%s\n' "$table" | tr ' ' '\n' | grep -c .)
  block=$(awk -v v="$varname" '
    $0 == "    var " v ": String {" { inblk = 1; next }
    inblk && /^    \}$/ { inblk = 0 }
    inblk { print }
  ' "$file")
  [ -n "$block" ] || die "no non-optional 'var ${varname}: String' block found in ${file}"
  bad=$(printf '%s\n' "$block" | grep -vE "^        switch self \{\$|^        \}\$|^        case \.[A-Za-z0-9_]+: return \"[0-9a-f]{${hexlen}}\"\$" || true)
  [ -z "$bad" ] || die "unexpected line(s) in ${varname} of ${file} (no nil/default/optional/uppercase/wrong length allowed): ${bad}"
  values=$(printf '%s\n' "$block" | sed -nE "s/^        case \.([A-Za-z0-9_]+): return \"([0-9a-f]{${hexlen}})\"\$/\1 \2/p")
  n=$(count_lines "$values")
  [ "$n" -eq "$expected" ] || die "expected exactly ${expected} entries in ${varname} of ${file}, found ${n}"
  for row in $table; do
    c=$(printf '%s\n' "$values" | awk -v k="${row%%|*}" '$1 == k' | grep -c . || true)
    [ "$c" -eq 1 ] || die "expected exactly one ${varname} entry for ${row%%|*} in ${file}, found ${c}"
  done
  printf '%s\n' "$values"
}

extract_whisper_revision() {
  local lines rev
  lines=$(grep -E '^    static let revision = ' "$WHISPER_PINS_FILE" || true)
  [ "$(count_lines "$lines")" -eq 1 ] || die "expected exactly one 'static let revision' line in ${WHISPER_PINS_FILE}"
  rev=$(printf '%s\n' "$lines" | sed -nE 's/^    static let revision = "([0-9a-f]{40})"$/\1/p')
  [ -n "$rev" ] || die "revision in ${WHISPER_PINS_FILE} is not a 40-char lowercase hex commit sha"
  printf '%s\n' "$rev"
}

# The enum in <file> must declare exactly the cases of <table>, with these raw values.
check_enum() { # file enumname table
  local file="$1" enum="$2" table="$3" cases row expected
  expected=$(printf '%s\n' "$table" | tr ' ' '\n' | grep -c .)
  cases=$(awk -v e="$enum" '$0 ~ "^enum " e "[: ]" { i = 1; next } i && /^}/ { i = 0 } i && /^    case /' "$file")
  [ "$(count_lines "$cases")" -eq "$expected" ] || die "enum ${enum} in ${file} has a different case count than this script's table"
  for row in $table; do
    printf '%s\n' "$cases" | grep -qxF "    case ${row%%|*} = \"$(printf '%s' "$row" | cut -d'|' -f2)\"" \
      || die "enum ${enum} is missing: case ${row%%|*} = \"$(printf '%s' "$row" | cut -d'|' -f2)\""
  done
}

check_whisper_shape() {
  check_enum "$WHISPER_ENUM_FILE" WhisperModel "$WHISPER_MODELS"
  grep -qxF -- "$WHISPER_URL_LINE" "$WHISPER_PINS_FILE" \
    || die "downloadURL in ${WHISPER_PINS_FILE} must be exactly the revision-pinned URL (resolve/\\(Self.revision), not main)"
  [ "$(grep -c 'resolve/' "$WHISPER_PINS_FILE" || true)" -eq 1 ] || die "unexpected extra resolve/ URL in ${WHISPER_PINS_FILE}"
}

# Llama: each case has its own repo, so revision and URL are per-case.
check_llama_shape() {
  local row case_name repo file
  check_enum "$LLAMA_ENUM_FILE" LlamaModel "$LLAMA_MODELS"
  for row in $LLAMA_MODELS; do
    case_name=$(printf '%s' "$row" | cut -d'|' -f1)
    repo=$(printf '%s' "$row" | cut -d'|' -f3)
    file=$(printf '%s' "$row" | cut -d'|' -f4)
    grep -qxF -- "            return URL(string: \"https://huggingface.co/${repo}/resolve/\\(revision)/${file}\")!" "$LLAMA_PINS_FILE" \
      || die "downloadURL for ${case_name} in ${LLAMA_PINS_FILE} must be exactly https://huggingface.co/${repo}/resolve/\\(revision)/${file}"
  done
  local n_resolve n_rows
  n_resolve=$(grep -c 'resolve/' "$LLAMA_PINS_FILE" || true)
  n_rows=$(printf '%s\n' "$LLAMA_MODELS" | tr ' ' '\n' | grep -c .)
  [ "$n_resolve" -eq "$n_rows" ] || die "unexpected number of resolve/ URLs in ${LLAMA_PINS_FILE} (${n_resolve}, expected ${n_rows})"
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

# Current commit sha of a Hugging Face model repo (print/bootstrap mode only).
hf_current_revision() { # repo
  local info
  info=$(fetch_text "https://huggingface.co/api/models/$1") || return 1
  printf '%s' "$info" | grep -oE '"sha":"[0-9a-f]{40}"' | head -1 | sed -E 's/.*"([0-9a-f]{40})"/\1/'
}

# ---- per-model check --------------------------------------------------------

# check_model <family> <case> <raw> <repo> <file> <revision> <pin|""> <use_readme 0|1>
check_model() {
  local family="$1" case_name="$2" raw="$3" repo="$4" file="$5" revision="$6" pin="$7" use_readme="$8"
  local url="https://huggingface.co/${repo}/resolve/${revision}/${file}"
  # Never let an empty extraction turn into a vacuous pass: in verify mode a
  # model without a pin and revision from the Swift source is a failure.
  if [ "$MODE" = "verify" ] && { [ -z "$pin" ] || [ -z "$revision" ]; }; then
    fail "${raw}: no pin/revision found in the Swift source"
    return
  fi
  local tmp="${WORK}/${file}"
  echo "==> ${family}/${raw}: downloading ${url}"
  if ! fetch "$url" "$tmp"; then
    fail "${raw}: download failed (${url})"
    return
  fi
  local tree lfs lfs_n dl256 dl1 size readme1="" readme_n=1
  dl256=$(hash_of 256 "$tmp"); dl1=$(hash_of 1 "$tmp"); size=$(wc -c <"$tmp" | tr -d ' ')
  rm -f "$tmp"
  tree=$(fetch_text "https://huggingface.co/api/models/${repo}/tree/${revision}") \
    || { fail "${raw}: revision ${revision} does not resolve via the HF tree API"; return; }
  lfs=$(lfs_oid_for "$tree" "$file"); lfs_n=$(count_lines "$lfs")
  if [ "$use_readme" = "1" ]; then
    readme1=$(readme_sha1_for "$README" "$raw"); readme_n=$(count_lines "$readme1")
  fi

  echo "    revision        ${revision}"
  echo "    size            ${size} bytes"
  echo "    sha256 (bytes)  ${dl256}"
  echo "    sha256 (HF LFS) ${lfs:-<missing>}"
  if [ "$use_readme" = "1" ]; then
    echo "    sha1   (bytes)  ${dl1}"
    echo "    sha1   (README) ${readme1:-<missing>}"
  fi
  [ -z "$pin" ] || echo "    sha256 (pin)    ${pin}"
  summary "| ${family} \`${raw}\` | \`${revision}\` | \`${dl256}\` | \`${lfs:-missing}\` | \`${readme1:-n/a}\` |"
  echo "PIN|${family}|${case_name}|${raw}|${revision}|${dl256}"

  [ "$lfs_n" -eq 1 ] || { fail "${raw}: expected exactly 1 LFS oid from the HF tree API, got ${lfs_n}"; return; }
  [ "$dl256" = "$lfs" ] || fail "${raw}: sha256 of downloaded bytes (${dl256}) != HF LFS oid (${lfs})"
  if [ "$use_readme" = "1" ]; then
    if [ "$readme_n" -ne 1 ]; then
      fail "${raw}: expected exactly 1 SHA-1 row in the whisper.cpp README, got ${readme_n}"
    elif [ "$dl1" != "$readme1" ]; then
      fail "${raw}: sha1 of downloaded bytes (${dl1}) != whisper.cpp README (${readme1})"
    fi
  fi
  if [ -n "$pin" ] && [ "$dl256" != "$pin" ]; then
    fail "${raw}: pin in the Swift source (${pin}) != sha256 of bytes at revision (${dl256})"
  fi
  return 0
}

lookup() { # "key value" lines, key
  printf '%s\n' "$1" | awk -v k="$2" '$1 == k {print $2}'
}

run_family() { # family table use_readme
  local family="$1" table="$2" use_readme="$3"
  local row case_name raw repo file revision pin wrev="" wpins="" lrevs="" lpins=""

  if [ "$MODE" = "verify" ]; then
    if [ "$family" = "whisper" ]; then
      check_whisper_shape
      wrev=$(extract_whisper_revision) || exit 1
      wpins=$(extract_switch "$WHISPER_PINS_FILE" expectedSHA256 64 "$table") || exit 1
    else
      check_llama_shape
      lrevs=$(extract_switch "$LLAMA_PINS_FILE" revision 40 "$table") || exit 1
      lpins=$(extract_switch "$LLAMA_PINS_FILE" expectedSHA256 64 "$table") || exit 1
    fi
  fi

  for row in $table; do
    case_name=$(printf '%s' "$row" | cut -d'|' -f1)
    raw=$(printf '%s' "$row" | cut -d'|' -f2)
    repo=$(printf '%s' "$row" | cut -d'|' -f3)
    file=$(printf '%s' "$row" | cut -d'|' -f4)
    if [ "$MODE" = "print" ]; then
      revision=$(hf_current_revision "$repo") || revision=""
      [ -n "$revision" ] || { fail "${raw}: could not read the current commit of ${repo}"; continue; }
      pin=""
    elif [ "$family" = "whisper" ]; then
      revision="$wrev"; pin=$(lookup "$wpins" "$case_name")
    else
      revision=$(lookup "$lrevs" "$case_name"); pin=$(lookup "$lpins" "$case_name")
    fi
    check_model "$family" "$case_name" "$raw" "$repo" "$file" "$revision" "$pin" "$use_readme"
  done
}

# ---- main -------------------------------------------------------------------

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --print) MODE="print" ;;
      --only) shift; ONLY="${1:-}"; case "$ONLY" in whisper|llama) ;; *) die "--only takes whisper or llama" ;; esac ;;
      -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done
  command -v curl >/dev/null 2>&1 || die "curl is required"

  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT

  summary "### Model pins (${MODE})"
  summary ""
  summary "| model | revision | sha256 (bytes) | sha256 (HF LFS) | sha1 (README) |"
  summary "|---|---|---|---|---|"

  if [ -z "$ONLY" ] || [ "$ONLY" = "whisper" ]; then
    README=$(fetch_text "$README_URL") || die "could not fetch the whisper.cpp README from ${README_URL}"
    run_family whisper "$WHISPER_MODELS" 1
  fi
  if [ -z "$ONLY" ] || [ "$ONLY" = "llama" ]; then
    run_family llama "$LLAMA_MODELS" 0
  fi

  if [ "$FAILURES" -gt 0 ]; then
    summary ""
    summary "**${FAILURES} check(s) FAILED** - see the log."
    echo "${FAILURES} check(s) failed." >&2
    exit 1
  fi
  echo "All sources agree for every checked model (mode: ${MODE})."
  summary ""
  summary "All sources agree for every checked model."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
