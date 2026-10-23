#!/usr/bin/env bash
# Checks the prebuilt llama.cpp / whisper.cpp XCFramework pins against upstream.
#
# Reads the pinned build tag from Packages/LlamaCpp/Package.swift and
# Packages/WhisperCpp/Package.swift, then asks the GitHub API for:
#   - the newest published build tag (bNNNN)        -> older pin = drift WARNING
#   - published security advisories for the repo    -> any that affects the pin
#     = FAILURE. An advisory affects the pin when a "<= bN" / "< bN" / "bN"
#     vulnerable range covers it, or a "bN" / ">= bN" patched version is newer
#     than the pin; a range that can't be read as a build number counts only if
#     the advisory was published after the pinned release.
#
# Exit: 0 clean (drift only warns), 1 advisory affects a pin, 2 usage/API error.
# Uses GITHUB_TOKEN / GH_TOKEN for rate limits when set. Needs curl + python3.
#
# Usage:
#   scripts/check-runtime-pins.sh
#   scripts/check-runtime-pins.sh --self-test   fixture JSON, no network

set -uo pipefail
cd "$(dirname "$0")/.."

PACKAGES="Packages/LlamaCpp/Package.swift Packages/WhisperCpp/Package.swift"
FIXTURES=""
WARN_PREFIX=""; [ -n "${GITHUB_ACTIONS:-}" ] && WARN_PREFIX="::warning::"

die() { echo "ERROR: $*" >&2; exit 2; }

# api <owner/repo> <kind> [tag]  -> JSON on stdout
api() {
  local repo="$1" kind="$2" tag="${3:-}" url f
  if [ -n "$FIXTURES" ]; then
    f="$FIXTURES/${repo//\//_}.${kind}${tag:+.$tag}.json"
    [ -f "$f" ] || die "no fixture $f"
    cat "$f"; return
  fi
  case "$kind" in
    releases) url="https://api.github.com/repos/$repo/releases?per_page=50" ;;
    release) url="https://api.github.com/repos/$repo/releases/tags/$tag" ;;
    advisories) url="https://api.github.com/repos/$repo/security-advisories?state=published&per_page=100" ;;
  esac
  local auth=()
  local tok="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [ -n "$tok" ] && auth=(-H "Authorization: Bearer $tok")
  curl --fail --silent --show-error --location --retry 3 --retry-all-errors \
    -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "$url" \
    || die "GitHub API request failed: $url"
}

# Prints "<owner/repo> <tag>" from a Package.swift binaryTarget url.
pin_of() {
  sed -nE 's#^[[:space:]]*url: "https://github\.com/([^/]+/[^/]+)/releases/download/(b[0-9]+)/.*",?$#\1 \2#p' "$1"
}

# evaluate <tag> <releases.json> <pinrelease.json> <advisories.json>
# prints DRIFT / ADVISORY lines; exit 1 if any ADVISORY.
evaluate() {
  python3 -I - "$@" <<'PY'
import json, re, sys
def main():
  tag, rel_f, pin_f, adv_f = sys.argv[1:5]
  pin_n = int(tag[1:])
  releases = json.load(open(rel_f))
  pin_rel = json.load(open(pin_f))
  advs = json.load(open(adv_f))

  builds = [r["tag_name"] for r in releases
            if re.fullmatch(r"b\d+", r["tag_name"]) and not r.get("draft")]
  latest = max(builds, key=lambda t: int(t[1:])) if builds else None
  if latest and int(latest[1:]) > pin_n:
      print(f"DRIFT pinned {tag}, newest build {latest}")
  elif latest:
      print(f"CURRENT pinned {tag} is the newest build")
  else:
      print("DRIFT no build tags found in the latest releases")

  pin_date = pin_rel.get("published_at") or ""
  bad = 0
  for a in advs:
      if a.get("state", "published") != "published":
          continue
      affects = False
      for v in a.get("vulnerabilities") or []:
          rng = (v.get("vulnerable_version_range") or "").replace(" ", "")
          m = re.fullmatch(r"(<=|<)b(\d+)", rng)
          e = re.fullmatch(r"b(\d+)", rng)
          if m:
              n = int(m.group(2))
              if pin_n < n or (m.group(1) == "<=" and pin_n == n):
                  affects = True
          elif e:
              if pin_n == int(e.group(1)):
                  affects = True
          elif (a.get("published_at") or "") > pin_date:
              affects = True
          fix = re.fullmatch(r"(>=)?b(\d+)", (v.get("patched_versions") or "").replace(" ", ""))
          if fix and pin_n < int(fix.group(2)):
              affects = True
      if not (a.get("vulnerabilities") or []) and (a.get("published_at") or "") > pin_date:
          affects = True
      if affects:
          bad = 1
          print(f"ADVISORY {a.get('ghsa_id')} ({a.get('severity')}) {(a.get('summary') or '')[:80]} {a.get('html_url','')}")
  return bad
try:
    sys.exit(main())
except Exception as exc:  # unexpected API shape: a usage/API error, never "advisory"
    print(f"ERROR could not read the API response: {exc!r}", file=sys.stderr)
    sys.exit(2)
PY
}

# check_repo <owner/repo> <tag> -> 0 ok, 1 advisory
check_repo() {
  local repo="$1" tag="$2" d rc out line
  d=$(mktemp -d)
  api "$repo" releases >"$d/rel.json" || exit 2
  api "$repo" release "$tag" >"$d/pin.json" || exit 2
  api "$repo" advisories >"$d/adv.json" || exit 2
  out=$(evaluate "$tag" "$d/rel.json" "$d/pin.json" "$d/adv.json"); rc=$?
  rm -rf "$d"
  [ "$rc" -le 1 ] || die "could not evaluate $repo"
  echo "==> $repo pinned $tag"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      DRIFT*) echo "${WARN_PREFIX}$repo: ${line#DRIFT }" ;;
      ADVISORY*) echo "ERROR: $repo: ${line#ADVISORY }" >&2 ;;
      *) echo "    $line" ;;
    esac
  done <<OUT
$out
OUT
  return "$rc"
}

run() { # package files...
  local pkg repo tag pins fail=0
  for pkg in "$@"; do
    pins=$(pin_of "$pkg")
    [ "$(printf '%s\n' "$pins" | grep -c .)" -eq 1 ] || die "expected exactly one release-download url in $pkg"
    read -r repo tag <<<"$pins"
    check_repo "$repo" "$tag" || fail=1
  done
  return $fail
}

self_test() {
  local d rc=0 out
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  FIXTURES="$d"
  mkdir -p "$d/pkg"
  cat >"$d/pkg/Package.swift" <<'SWIFT'
        .binaryTarget(
            name: "x",
            url: "https://github.com/o/r/releases/download/b100/x-b100-xcframework.zip",
            checksum: "00"
        )
SWIFT
  [ "$(pin_of "$d/pkg/Package.swift")" = "o/r b100" ] || { echo "FAIL - pin parse" >&2; rc=1; }

  echo '[{"tag_name":"v9.9.9"},{"tag_name":"b105"},{"tag_name":"b100"}]' >"$d/o_r.releases.json"
  echo '{"published_at":"2026-05-01T00:00:00Z"}' >"$d/o_r.release.b100.json"

  # 1. only a long-fixed advisory (<= b50) and newer build: warns, passes.
  echo '[{"ghsa_id":"GHSA-old","state":"published","severity":"high","published_at":"2026-01-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":"<= b50"}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 0 ] && printf '%s' "$out" | grep -q 'pinned b100, newest build b105' \
    || { echo "FAIL - drift should warn and pass: $out" >&2; rc=1; }

  # 2. advisory covering the pin: fails.
  echo '[{"ghsa_id":"GHSA-hit","state":"published","severity":"critical","published_at":"2026-06-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":"<= b100"}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] && printf '%s' "$out" | grep -q GHSA-hit \
    || { echo "FAIL - covering advisory should fail: $out" >&2; rc=1; }

  # 3. unreadable range, published after the pinned release: fails.
  echo '[{"ghsa_id":"GHSA-new","state":"published","severity":"high","published_at":"2026-06-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":""}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] || { echo "FAIL - post-pin unreadable advisory should fail" >&2; rc=1; }

  # 4. unreadable range, published before the pinned release: passes.
  echo '[{"ghsa_id":"GHSA-pre","state":"published","severity":"high","published_at":"2026-01-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":""}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 0 ] || { echo "FAIL - pre-pin advisory should pass" >&2; rc=1; }

  # 5. unreadable range published before the pin, but the patched build is newer than the pin: fails.
  echo '[{"ghsa_id":"GHSA-fix","state":"published","severity":"high","published_at":"2026-01-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":"All versions before patch","patched_versions":">= b101"}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] && printf '%s' "$out" | grep -q GHSA-fix \
    || { echo "FAIL - patched build newer than the pin should fail: $out" >&2; rc=1; }

  # 6. patched build at or below the pin, null summary: passes.
  echo '[{"ghsa_id":"GHSA-done","state":"published","severity":"high","summary":null,"published_at":"2026-01-01T00:00:00Z","vulnerabilities":[{"vulnerable_version_range":"<b90","patched_versions":"b100"}]}]' >"$d/o_r.advisories.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 0 ] || { echo "FAIL - advisory patched by the pin should pass: $out" >&2; rc=1; }

  # 7. an unexpected API shape is an API error (exit 2), not an advisory hit.
  echo '{"message":"Bad credentials"}' >"$d/o_r.advisories.json"
  (run "$d/pkg/Package.swift") >/dev/null 2>&1; [ $? -eq 2 ] || { echo "FAIL - malformed API response should exit 2" >&2; rc=1; }

  # 8. no token and a bash without empty-array support under set -u: the real
  #    request path still runs (curl stubbed; prints the URL it was given).
  mkdir -p "$d/bin"; printf '#!/bin/sh\nfor a; do last="$a"; done; echo "$last"\n' >"$d/bin/curl"; chmod +x "$d/bin/curl"
  out=$(FIXTURES="" GITHUB_TOKEN="" GH_TOKEN="" PATH="$d/bin:$PATH" api o/r advisories 2>&1)
  [ "$out" = "https://api.github.com/repos/o/r/security-advisories?state=published&per_page=100" ] \
    || { echo "FAIL - tokenless API request: $out" >&2; rc=1; }

  [ "$rc" -eq 0 ] && echo "self-test passed"
  return $rc
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") command -v python3 >/dev/null && command -v curl >/dev/null || die "curl and python3 are required"
      run $PACKAGES; exit $? ;;
  *) die "usage: $0 [--self-test]" ;;
esac
