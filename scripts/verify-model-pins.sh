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
# The embedded LLM models in Sources/App/Services/Llama/LlamaModel.swift are
# checked too, from the Hugging Face tree API alone (no download): the pinned
# revision must resolve, and the file's LFS sha256 and byte size must match the
# pinned sha256 and the size recorded in the source.
#
# Usage:
#   scripts/verify-model-pins.sh           verify the pins in the Swift source
#   scripts/verify-model-pins.sh --print   bootstrap: use the CURRENT Hugging Face
#                                          revision and print what to pin (still
#                                          fails on any cross-source disagreement)
#   scripts/verify-model-pins.sh --self-test   offline fixture checks of the parsers
#
# Needs curl and sha256sum/shasum + sha1sum/shasum. Downloads ~5 GB in total, so
# it is meant for CI (see .github/workflows/verify-model-pins.yml), not every build.

set -uo pipefail
cd "$(dirname "$0")/.."

PINS_FILE="Sources/App/Services/WhisperModelPins.swift"
SETTINGS_FILE="Sources/App/Services/AppSettings.swift"
LLAMA_FILE="Sources/App/Services/Llama/LlamaModel.swift"
LLAMA_ORG="ggml-org"
LLAMA_EXPECTED_COUNT=2
# The one exact line that builds the LLM download URL from the pinned revision.
LLAMA_URL_LINE='        URL(string: "https://huggingface.co/ggml-org/\(repo)/resolve/\(revision)/\(fileName)")!'
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

# ---- LLM pins (LlamaModel.swift) --------------------------------------------

# Prints "<property> <case> <value>" for every `case .x: return <value>` line of
# the pinned computed properties. For approximateSizeMB the value is the exact
# byte count from the trailing "// 6,036,116,480 bytes" comment.
llama_fields() {
  awk '
    /^    (private )?var (fileName|repo|revision|expectedSHA256|approximateSizeMB): / {
      prop = $0; sub(/^    (private )?var /, "", prop); sub(/:.*/, "", prop); next
    }
    /^    }$/ { prop = "" }
    prop != "" && /^        case \.[A-Za-z0-9_]+: return / {
      c = $0; sub(/^        case \./, "", c); sub(/:.*/, "", c)
      if (prop == "approximateSizeMB") {
        if (match($0, /\/\/ [0-9,]+ bytes/)) {
          b = substr($0, RSTART + 3, RLENGTH - 9); gsub(/,/, "", b); print prop, c, b
        } else { print prop, c, "MISSING" }
      } else if (match($0, /return "[^"]*"/)) {
        v = substr($0, RSTART + 8, RLENGTH - 9); print prop, c, v
      } else { print prop, c, "MISSING" }
    }
  ' "$LLAMA_FILE"
}

# Strict: exactly LLAMA_EXPECTED_COUNT cases, each with every field, 40-hex
# revision, 64-hex sha, numeric size, a revision-pinned URL. Prints
# "<case>|<repo>|<revision>|<sha256>|<bytes>|<file>" per model.
extract_llama() {
  local fields cases c prop v row out=""
  [ -f "$LLAMA_FILE" ] || die "missing $LLAMA_FILE"
  grep -qxF -- "$LLAMA_URL_LINE" "$LLAMA_FILE" \
    || die "downloadURL in $LLAMA_FILE must be exactly the revision-pinned resolve/\\(revision) URL under ${LLAMA_ORG}"
  [ "$(grep -c 'resolve/' "$LLAMA_FILE" || true)" -eq 1 ] || die "unexpected extra resolve/ URL in $LLAMA_FILE"
  fields=$(llama_fields)
  cases=$(awk '/^enum LlamaModel/ { i = 1; next } i && /^}/ { i = 0 } i && /^    case [A-Za-z0-9_]+ = "/ { sub(/^    case /, ""); sub(/ =.*/, ""); print }' "$LLAMA_FILE")
  [ "$(count_lines "$cases")" -eq "$LLAMA_EXPECTED_COUNT" ] || die "expected exactly $LLAMA_EXPECTED_COUNT cases in enum LlamaModel, found $(count_lines "$cases")"
  for c in $cases; do
    row="$c"
    for prop in repo revision expectedSHA256 approximateSizeMB fileName; do
      v=$(printf '%s\n' "$fields" | awk -v p="$prop" -v c="$c" '$1 == p && $2 == c {print $3}')
      [ "$(count_lines "$v")" -eq 1 ] && [ "$v" != "MISSING" ] || die "LlamaModel.$c: need exactly one $prop value (with byte-count comment for approximateSizeMB)"
      case "$prop" in
        revision) printf '%s' "$v" | grep -qE '^[0-9a-f]{40}$' || die "LlamaModel.$c: revision is not a 40-char lowercase hex commit sha" ;;
        expectedSHA256) printf '%s' "$v" | grep -qE '^[0-9a-f]{64}$' || die "LlamaModel.$c: expectedSHA256 is not 64 lowercase hex" ;;
        approximateSizeMB) printf '%s' "$v" | grep -qE '^[0-9]+$' || die "LlamaModel.$c: size comment is not a byte count" ;;
      esac
      row="$row|$v"
    done
    out="${out}${row}
"
  done
  printf '%s' "$out"
}

lfs_size_for() { # tree_json file
  printf '%s' "$1" \
    | sed 's/{"type":/\
{"type":/g' \
    | grep -F "\"path\":\"$2\"" \
    | sed -nE 's/.*"lfs":\{"oid":"[0-9a-f]{64}","size":([0-9]+).*/\1/p'
}

# Compare one model's pins to a tree-API reading. Counts failures via fail().
llama_compare() { # case tree_json sha256 bytes file
  local c="$1" tree="$2" pin="$3" bytes="$4" file="$5" oid size
  oid=$(lfs_oid_for "$tree" "$file"); size=$(lfs_size_for "$tree" "$file")
  echo "    sha256 (HF LFS) ${oid:-<missing>}"
  echo "    sha256 (pin)    ${pin}"
  echo "    size   (HF LFS) ${size:-<missing>}"
  echo "    size   (source) ${bytes}"
  if [ "$(count_lines "$oid")" -ne 1 ] || [ "$(count_lines "$size")" -ne 1 ]; then
    fail "${c}: expected exactly 1 LFS entry for ${file} in the HF tree"
    return
  fi
  [ "$oid" = "$pin" ] || fail "${c}: pin (${pin}) != HF LFS oid (${oid})"
  [ "$size" = "$bytes" ] || fail "${c}: size in ${LLAMA_FILE} (${bytes}) != HF LFS size (${size})"
}

check_llama_models() {
  local rows c repo rev sha bytes file tree
  rows=$(extract_llama) || exit 1
  summary ""
  summary "### LLM pins"
  summary ""
  summary "| model | revision | sha256 (pin) | bytes |"
  summary "|---|---|---|---|"
  while IFS='|' read -r c repo rev sha bytes file; do
    [ -n "$c" ] || continue
    echo "==> ${c}: ${LLAMA_ORG}/${repo} @ ${rev}"
    summary "| \`${c}\` | \`${rev}\` | \`${sha}\` | ${bytes} |"
    if ! tree=$(curl --fail --location --silent --show-error --retry 3 --retry-all-errors \
      "https://huggingface.co/api/models/${LLAMA_ORG}/${repo}/tree/${rev}"); then
      fail "${c}: revision ${rev} does not resolve on Hugging Face (tree API failed)"
      continue
    fi
    llama_compare "$c" "$tree" "$sha" "$bytes" "$file"
  done <<ROWS
$rows
ROWS
}

# ---- self-test (offline) ----------------------------------------------------

self_test() {
  local d ok=1 rows wt
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  cat >"$d/Llama.swift" <<'SWIFT'
enum LlamaModel: String {
    case a1 = "a-one"
    case b2 = "b-two"

    var approximateSizeMB: Int {
        switch self {
        case .a1: return 6036   // 6,036,116,480 bytes
        case .b2: return 2841   // 2,841,481,184 bytes
        }
    }
    var fileName: String {
        switch self {
        case .a1: return "a.gguf"
        case .b2: return "b.gguf"
        }
    }
    private var repo: String {
        switch self {
        case .a1: return "A-GGUF"
        case .b2: return "B-GGUF"
        }
    }
    var revision: String {
        switch self {
        case .a1: return "0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8"
        case .b2: return "b4243c156154b6dca9324415f8c7ccc098b4aed1"
        }
    }
    var expectedSHA256: String {
        switch self {
        case .a1: return "b4778681efbd6898fe1965e74f810b3b7dfdf6afab01df9c88c1b0e6e9ca122d"
        case .b2: return "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
        }
    }
    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggml-org/\(repo)/resolve/\(revision)/\(fileName)")!
    }
}
SWIFT
  local good=b4778681efbd6898fe1965e74f810b3b7dfdf6afab01df9c88c1b0e6e9ca122d
  local tree='[{"type":"file","oid":"x","size":5,"path":"README.md"},{"type":"file","oid":"y","size":6036116480,"lfs":{"oid":"'$good'","size":6036116480,"pointerSize":135},"path":"a.gguf"}]'
  check() { # description exit-code (0 = pass)
    if [ "$2" -eq 0 ]; then echo "ok   - $1"; else echo "FAIL - $1" >&2; ok=0; fi
  }

  LLAMA_FILE="$d/Llama.swift"
  rows=$(extract_llama)
  [ "$(count_lines "$rows")" -eq 2 ] && printf '%s\n' "$rows" | grep -qx "a1|A-GGUF|0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8|${good}|6036116480|a.gguf"
  check "llama pins parse from source" $?

  FAILURES=0
  llama_compare a1 "$tree" $good 6036116480 a.gguf >/dev/null
  check "matching sha256 + size passes" "$FAILURES"

  FAILURES=0
  llama_compare a1 "$tree" 0000000000000000000000000000000000000000000000000000000000000000 6036116480 a.gguf >/dev/null 2>&1
  [ "$FAILURES" -eq 1 ]; check "tampered sha256 pin fails" $?

  FAILURES=0
  llama_compare a1 "$tree" $good 6036116481 a.gguf >/dev/null 2>&1
  [ "$FAILURES" -eq 1 ]; check "wrong size fails" $?

  FAILURES=0
  llama_compare a1 "$tree" $good 6036116480 missing.gguf >/dev/null 2>&1
  [ "$FAILURES" -eq 1 ]; check "file absent from tree fails" $?

  sed 's/0aba27dd2f1c7f4941a94a5c59d80e0a256f9ff8/main/' "$d/Llama.swift" >"$d/Bad.swift"
  (LLAMA_FILE="$d/Bad.swift"; extract_llama) >/dev/null 2>&1
  [ $? -ne 0 ]; check "non-commit revision is rejected" $?

  sed 's#resolve/\\(revision)#resolve/main#' "$d/Llama.swift" >"$d/Bad2.swift"
  (LLAMA_FILE="$d/Bad2.swift"; extract_llama) >/dev/null 2>&1
  [ $? -ne 0 ]; check "floating resolve/main URL is rejected" $?

  # The Whisper tree reading still parses (shared LFS helper).
  wt='[{"type":"file","oid":"y","size":9,"lfs":{"oid":"'$good'","size":9,"pointerSize":1},"path":"ggml-base.en.bin"}]'
  [ "$(lfs_oid_for "$wt" ggml-base.en.bin)" = "$good" ]
  check "whisper LFS oid parse" $?

  [ "$ok" -eq 1 ] || { echo "self-test FAILED" >&2; return 1; }
  echo "self-test passed"
}

# ---- main -------------------------------------------------------------------

main() {
  case "${1:-}" in
    "") MODE="verify" ;;
    --print) MODE="print" ;;
    --self-test) self_test; exit $? ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (use --print, --self-test or no arguments)" ;;
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

  check_llama_models

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
