#!/usr/bin/env bash
# Checks the prebuilt llama.cpp / whisper.cpp XCFramework pins against upstream.
#
# Reads the pins from the `// upstream: <repo> <tag> <commit>` and
# `// upstream-zip: <sha256>` lines in Packages/LlamaCpp/Package.swift and
# Packages/WhisperCpp/Package.swift. Offline (--local, and first in every run)
# it checks that the binaryTarget is either upstream's zip for that tag with
# the upstream-zip checksum, or our AVX2 x86_64 build of the same tag
# (<name>-<tag>-x86avx2-xcframework.zip on a runtime-x86avx2-* prerelease of
# this repo, checked against a rebuild by .github/workflows/runtime-x86.yml).
# Online it also checks that the tag still names the pinned commit, that
# upstream's zip still has the pinned SHA-256 (the release asset digest), that
# our build, when pinned, is still on a prerelease with the pinned digest, and
# asks the GitHub API for:
#   - the newest published build tag (bNNNN)        -> older pin = drift WARNING
#   - published security advisories for the repo    -> any that affects the pin
#     = FAILURE. An advisory affects the pin when a "<= bN" / "< bN" / "bN"
#     vulnerable range covers it, or a "bN" / ">= bN" patched version is newer
#     than the pin; a range that can't be read as a build number counts only if
#     the advisory was published after the pinned release.
#
# Exit: 0 clean (drift only warns), 1 a pin is inconsistent or an advisory
# affects it, 2 usage/API error.
# Uses GITHUB_TOKEN / GH_TOKEN for rate limits when set. Needs curl + python3.
#
# Usage:
#   scripts/check-runtime-pins.sh
#   scripts/check-runtime-pins.sh --local       pin consistency only, no network
#   scripts/check-runtime-pins.sh --self-test   fixture JSON, no network

set -uo pipefail
cd "$(dirname "$0")/.."

PACKAGES="Packages/LlamaCpp/Package.swift Packages/WhisperCpp/Package.swift"
OUR_RELEASES="https://github.com/mgwedd/aletheia/releases/download"
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

# Prints "<owner/repo> <tag> <commit>" from a Package.swift `// upstream:` line.
pin_of() {
  sed -nE 's#^// upstream: ([^/ ]+/[^/ ]+) (b[0-9]+) ([0-9a-f]{40})$#\1 \2 \3#p' "$1"
}

# field <Package.swift> <upstream-zip|url|checksum|name>
field() {
  case "$2" in
    upstream-zip) sed -nE 's#^// upstream-zip: ([0-9a-f]{64})$#\1#p' "$1" ;;
    url) sed -nE 's#^[[:space:]]*url: "([^"]+)",?$#\1#p' "$1" ;;
    checksum) sed -nE 's#^[[:space:]]*checksum: "([0-9a-f]{64})",?$#\1#p' "$1" ;;
    name) sed -nE 's#^[[:space:]]*name: "([^"]+)",?$#\1#p' "$1" | tail -1 ;;
  esac
}

# check_local <Package.swift> -> prints "<repo> <tag> <commit> <upstream-zip> <name>"; 1 if inconsistent
check_local() {
  local pkg="$1" pins repo tag commit up url sum name n
  pins=$(pin_of "$pkg")
  for n in "$pins" "$(field "$pkg" upstream-zip)" "$(field "$pkg" url)" "$(field "$pkg" checksum)"; do
    [ "$(printf '%s\n' "$n" | grep -c .)" -eq 1 ] \
      || { echo "ERROR: $pkg needs exactly one // upstream:, // upstream-zip:, url and checksum line" >&2; return 1; }
  done
  read -r repo tag commit <<<"$pins"
  up=$(field "$pkg" upstream-zip); url=$(field "$pkg" url); sum=$(field "$pkg" checksum); name=$(field "$pkg" name)
  case "$url" in
    "https://github.com/$repo/releases/download/$tag/$name-$tag-xcframework.zip")
      [ "$sum" = "$up" ] || { echo "ERROR: $pkg uses upstream's zip but its checksum is not the upstream-zip pin" >&2; return 1; } ;;
    "$OUR_RELEASES"/runtime-x86avx2-*/"$name-$tag-x86avx2-xcframework.zip")
      case "${url#"$OUR_RELEASES"/}" in
        runtime-x86avx2-*"$tag"*/*) ;;
        *) echo "ERROR: $pkg: release ${url#"$OUR_RELEASES"/} does not name $tag" >&2; return 1 ;;
      esac ;;
    *) echo "ERROR: $pkg: $url is neither upstream's $tag zip nor our x86avx2 build of it" >&2; return 1 ;;
  esac
  echo "$repo $tag $commit $up $name"
}

# tag_commit <owner/repo> <tag> -> the commit the tag names (peeled)
tag_commit() {
  if [ -n "$FIXTURES" ]; then cat "$FIXTURES/${1//\//_}.tag.$2" 2>/dev/null; return; fi
  git ls-remote "https://github.com/$1.git" "refs/tags/$2" "refs/tags/$2^{}" | awk 'END { print $1 }'
}

# evaluate <tag> <releases.json> <pinrelease.json> <advisories.json> <asset> <sha256>
# prints DRIFT / ADVISORY / ASSET lines; exit 1 if any ADVISORY or ASSET mismatch.
evaluate() {
  python3 -I - "$@" <<'PY'
import json, re, sys
def main():
  tag, rel_f, pin_f, adv_f, asset, want = sys.argv[1:7]
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
  found = [a for a in pin_rel.get("assets") or [] if a.get("name") == asset]
  if not found:
      bad = 1
      print(f"ASSET {asset} is no longer on the {tag} release")
  elif found[0].get("digest") and found[0]["digest"] != "sha256:" + want:
      bad = 1
      print(f"ASSET {asset} is now {found[0]['digest']}, pinned sha256:{want}")
  elif not found[0].get("digest"):
      print(f"DRIFT {asset} has no digest to compare")
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

# check_repo <owner/repo> <tag> <commit> <upstream-zip> <name> -> 0 ok, 1 advisory or mismatch
check_repo() {
  local repo="$1" tag="$2" commit="$3" up="$4" name="$5" d rc out line tagged
  d=$(mktemp -d)
  api "$repo" releases >"$d/rel.json" || exit 2
  api "$repo" release "$tag" >"$d/pin.json" || exit 2
  api "$repo" advisories >"$d/adv.json" || exit 2
  out=$(evaluate "$tag" "$d/rel.json" "$d/pin.json" "$d/adv.json" "$name-$tag-xcframework.zip" "$up"); rc=$?
  rm -rf "$d"
  [ "$rc" -le 1 ] || die "could not evaluate $repo"
  echo "==> $repo pinned $tag"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      DRIFT*) echo "${WARN_PREFIX}$repo: ${line#DRIFT }" ;;
      ADVISORY*) echo "ERROR: $repo: ${line#ADVISORY }" >&2 ;;
      ASSET*) echo "ERROR: $repo: ${line#ASSET }" >&2 ;;
      *) echo "    $line" ;;
    esac
  done <<OUT
$out
OUT
  tagged=$(tag_commit "$repo" "$tag")
  if [ "$tagged" != "$commit" ]; then
    echo "ERROR: $repo: tag $tag names ${tagged:-nothing}, pinned $commit" >&2
    rc=1
  fi
  return "$rc"
}

# check_ours <Package.swift> -> 0 when the url is upstream's, or our release
# still serves that asset with the pinned SHA-256 (its digest); 1 otherwise.
check_ours() {
  local pkg="$1" url sum rel asset d got
  url=$(field "$pkg" url); sum=$(field "$pkg" checksum)
  case "$url" in "$OUR_RELEASES"/*) ;; *) return 0 ;; esac
  rel=${url#"$OUR_RELEASES"/}; asset=${rel#*/}; rel=${rel%%/*}
  d=$(mktemp -d)
  api mgwedd/aletheia release "$rel" >"$d/rel.json" || exit 2
  got=$(python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1])); a=[x for x in r.get("assets") or [] if x.get("name")==sys.argv[2]]
print(("pre" if r.get("prerelease") else "not-pre") + " " + ((a[0].get("digest") or "none") if a else "missing"))' "$d/rel.json" "$asset") || got="error"
  rm -rf "$d"
  case "$got" in
    "pre sha256:$sum") echo "==> $rel/$asset: digest matches the pin" ;;
    not-pre*) echo "ERROR: $pkg: $rel is not a prerelease, so the app's update check could pick it up" >&2; return 1 ;;
    *) echo "ERROR: $pkg: $rel/$asset is $got, pinned sha256:$sum" >&2; return 1 ;;
  esac
}

run() { # [--local] package files...
  local pkg pins fail=0 local_only=0
  [ "${1:-}" = --local ] && { local_only=1; shift; }
  for pkg in "$@"; do
    pins=$(check_local "$pkg") || { fail=1; continue; }
    [ "$local_only" -eq 1 ] && { echo "==> $pkg: $pins"; continue; }
    # shellcheck disable=SC2086
    check_repo $pins || fail=1
    check_ours "$pkg" || fail=1
  done
  return $fail
}

self_test() {
  local d rc=0 out
  d=$(mktemp -d); trap 'rm -rf "$d"' RETURN
  FIXTURES="$d"
  mkdir -p "$d/pkg"
  local c40=1111111111111111111111111111111111111111 z=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  local y=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  pkgfile() { # pkgfile <url> <checksum> -> writes $d/pkg/Package.swift
    cat >"$d/pkg/Package.swift" <<SWIFT
// upstream: o/r b100 $c40
// upstream-zip: $z
        .binaryTarget(
            name: "x",
            url: "$1",
            checksum: "$2"
        )
SWIFT
  }
  local up_url="https://github.com/o/r/releases/download/b100/x-b100-xcframework.zip"
  pkgfile "$up_url" "$z"
  [ "$(pin_of "$d/pkg/Package.swift")" = "o/r b100 $c40" ] || { echo "FAIL - pin parse" >&2; rc=1; }

  # Local consistency: upstream's zip with its pinned checksum, or our x86avx2 build of the same tag.
  run --local "$d/pkg/Package.swift" >/dev/null 2>&1 || { echo "FAIL - upstream zip with its pin should pass" >&2; rc=1; }
  pkgfile "$up_url" "$y"
  (run --local "$d/pkg/Package.swift") >/dev/null 2>&1 && { echo "FAIL - upstream zip with another checksum should fail" >&2; rc=1; }
  pkgfile "$OUR_RELEASES/runtime-x86avx2-b100-b7/x-b100-x86avx2-xcframework.zip" "$y"
  run --local "$d/pkg/Package.swift" >/dev/null 2>&1 || { echo "FAIL - our x86avx2 build of the tag should pass" >&2; rc=1; }
  pkgfile "$OUR_RELEASES/runtime-x86avx2-b99-b7/x-b100-x86avx2-xcframework.zip" "$y"
  (run --local "$d/pkg/Package.swift") >/dev/null 2>&1 && { echo "FAIL - a release naming another tag should fail" >&2; rc=1; }
  pkgfile "$OUR_RELEASES/runtime-x86avx2-b100-b7/x-b99-x86avx2-xcframework.zip" "$y"
  (run --local "$d/pkg/Package.swift") >/dev/null 2>&1 && { echo "FAIL - an asset built from another tag should fail" >&2; rc=1; }
  pkgfile "https://example.com/x-b100-xcframework.zip" "$z"
  (run --local "$d/pkg/Package.swift") >/dev/null 2>&1 && { echo "FAIL - any other host should fail" >&2; rc=1; }
  pkgfile "$up_url" "$z"

  echo '[{"tag_name":"v9.9.9"},{"tag_name":"b105"},{"tag_name":"b100"}]' >"$d/o_r.releases.json"
  echo "{\"published_at\":\"2026-05-01T00:00:00Z\",\"assets\":[{\"name\":\"x-b100-xcframework.zip\",\"digest\":\"sha256:$z\"}]}" >"$d/o_r.release.b100.json"
  echo "$c40" >"$d/o_r.tag.b100"

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

  # 8. the tag moved to another commit, or upstream's zip changed: fails.
  echo '[]' >"$d/o_r.advisories.json"
  echo 2222222222222222222222222222222222222222 >"$d/o_r.tag.b100"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] && printf '%s' "$out" | grep -q 'tag b100 names 2222' \
    || { echo "FAIL - a moved tag should fail: $out" >&2; rc=1; }
  echo "$c40" >"$d/o_r.tag.b100"
  echo "{\"published_at\":\"2026-05-01T00:00:00Z\",\"assets\":[{\"name\":\"x-b100-xcframework.zip\",\"digest\":\"sha256:$y\"}]}" >"$d/o_r.release.b100.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] && printf '%s' "$out" | grep -q 'pinned sha256' \
    || { echo "FAIL - a replaced upstream zip should fail: $out" >&2; rc=1; }
  echo '{"published_at":"2026-05-01T00:00:00Z","assets":[]}' >"$d/o_r.release.b100.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] || { echo "FAIL - a missing upstream zip should fail: $out" >&2; rc=1; }

  # 9. our x86avx2 build: the prerelease must serve the pinned digest.
  echo "{\"published_at\":\"2026-05-01T00:00:00Z\",\"assets\":[{\"name\":\"x-b100-xcframework.zip\",\"digest\":\"sha256:$z\"}]}" >"$d/o_r.release.b100.json"
  pkgfile "$OUR_RELEASES/runtime-x86avx2-b100-b7/x-b100-x86avx2-xcframework.zip" "$y"
  echo "{\"prerelease\":true,\"assets\":[{\"name\":\"x-b100-x86avx2-xcframework.zip\",\"digest\":\"sha256:$y\"}]}" >"$d/mgwedd_aletheia.release.runtime-x86avx2-b100-b7.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 0 ] || { echo "FAIL - our build with its digest should pass: $out" >&2; rc=1; }
  echo "{\"prerelease\":true,\"assets\":[{\"name\":\"x-b100-x86avx2-xcframework.zip\",\"digest\":\"sha256:$z\"}]}" >"$d/mgwedd_aletheia.release.runtime-x86avx2-b100-b7.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] || { echo "FAIL - our build with another digest should fail: $out" >&2; rc=1; }
  echo "{\"prerelease\":false,\"assets\":[{\"name\":\"x-b100-x86avx2-xcframework.zip\",\"digest\":\"sha256:$y\"}]}" >"$d/mgwedd_aletheia.release.runtime-x86avx2-b100-b7.json"
  out=$(run "$d/pkg/Package.swift" 2>&1); [ $? -eq 1 ] || { echo "FAIL - a full release should fail: $out" >&2; rc=1; }
  pkgfile "$up_url" "$z"

  # 10. no token and a bash without empty-array support under set -u: the real
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
  --local) run --local $PACKAGES; exit $? ;;
  "") command -v python3 >/dev/null && command -v curl >/dev/null || die "curl and python3 are required"
      run $PACKAGES; exit $? ;;
  *) die "usage: $0 [--self-test]" ;;
esac
