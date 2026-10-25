#!/usr/bin/env bash
# Checks the GitHub repository settings that the supply-chain and release rules rely on.
#
#   1. Actions: sha_pinning_required is true (third-party actions must be pinned to a commit SHA).
#   2. Tags: an active ruleset targets tags, covers refs/tags/v*, and has the
#      creation, update and deletion rules (released tags cannot be moved or removed).
#   3. Default branch: an active branch ruleset covers ~DEFAULT_BRANCH and has the
#      deletion, non_fast_forward, required_status_checks, pull_request and
#      required_signatures rules.
#
# Exit: 0 all settings hold, 1 a setting does not hold, 2 usage or API error.
#
# Usage: scripts/check-repo-settings.sh                  live check via gh api (needs admin read access)
#        scripts/check-repo-settings.sh --repo OWNER/REPO
#        scripts/check-repo-settings.sh --fixtures DIR    read permissions.json, rulesets.json and
#                                                         ruleset-<id>.json from DIR, no network
#        scripts/check-repo-settings.sh --self-test        fixture cases, one failing case per check
#
# CI runs only --self-test (the live check needs an admin token). Needs gh and jq.

set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

REPO="mgwedd/aletheia"
FIXTURES=""
MODE="check"
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?usage: --repo OWNER/REPO}"; shift 2 ;;
        --fixtures) FIXTURES="${2:?usage: --fixtures DIR}"; shift 2 ;;
        --self-test) MODE="self-test"; shift ;;
        -h|--help) sed -n '2,19p' "$SCRIPT"; exit 0 ;;
        *) echo "usage: $0 [--repo OWNER/REPO] [--fixtures DIR] [--self-test]" >&2; exit 2 ;;
    esac
done

fail=0
err() { echo "check-repo-settings: $*" >&2; fail=1; }

# fetch <fixture-file> <api-path>: JSON on stdout (from FIXTURES when set, else gh api).
fetch() {
    if [ -n "$FIXTURES" ]; then
        if [ ! -f "$FIXTURES/$1" ]; then
            echo "check-repo-settings: missing fixture $FIXTURES/$1" >&2
            exit 2
        fi
        cat "$FIXTURES/$1"
    else
        if ! gh api "$2"; then
            echo "check-repo-settings: gh api $2 failed (needs gh auth and admin read access)" >&2
            exit 2
        fi
    fi
}

# Filters over the array of full ruleset objects; `jq -e` exits 0 when one ruleset matches.
TAG_JQ='any(.[];
    .target == "tag" and .enforcement == "active"
    and ((.conditions.ref_name.include // []) | any(. == "refs/tags/v*"))
    and ([.rules[]?.type] as $t | all(["creation", "update", "deletion"][]; . as $w | any($t[]; . == $w))))'
DEFAULT_JQ='any(.[];
    .target == "branch" and .enforcement == "active"
    and ((.conditions.ref_name.include // []) | any(. == "~DEFAULT_BRANCH"))
    and ([.rules[]?.type] as $t | all(["deletion", "non_fast_forward", "required_status_checks", "pull_request", "required_signatures"][]; . as $w | any($t[]; . == $w))))'

check() {
    local perms rulesets details id d
    perms="$(fetch permissions.json "repos/$REPO/actions/permissions")"
    rulesets="$(fetch rulesets.json "repos/$REPO/rulesets")"
    details="[]"
    for id in $(jq -r '.[].id' <<<"$rulesets"); do
        d="$(fetch "ruleset-$id.json" "repos/$REPO/rulesets/$id")"
        details="$(jq --argjson r "$d" '. + [$r]' <<<"$details")"
    done

    if [ "$(jq -r '.sha_pinning_required' <<<"$perms")" != "true" ]; then
        err "$REPO: actions sha_pinning_required is not true (pin actions to full commit SHAs)"
    fi
    if ! jq -e "$TAG_JQ" >/dev/null <<<"$details"; then
        err "$REPO: no active tag ruleset covers refs/tags/v* with creation, update and deletion rules"
    fi
    if ! jq -e "$DEFAULT_JQ" >/dev/null <<<"$details"; then
        err "$REPO: no active branch ruleset covers ~DEFAULT_BRANCH with deletion, non_fast_forward, required_status_checks, pull_request and required_signatures rules"
    fi
}

# ---- --self-test: fixture sets, a passing one and one failing case per check ----
self_test() {
    local d bad=0 set_dir
    d="$(mktemp -d)"
    trap "rm -rf '$d'" EXIT

    rules_json() { # rules_json "type type ..." -> JSON array
        local out="" t
        for t in $1; do out="${out:+$out,}{\"type\":\"$t\"}"; done
        printf '[%s]' "$out"
    }
    ruleset_json() { # ruleset_json <id> <target> <enforcement> <ref> "<rule types>"
        printf '{"id":%s,"target":"%s","enforcement":"%s","conditions":{"ref_name":{"include":["%s"],"exclude":[]}},"rules":%s}' \
            "$1" "$2" "$3" "$4" "$(rules_json "$5")"
    }
    # make_set <dir> <sha_pinning> <tag enforcement> <tag rule types> <branch rule types>
    make_set() {
        mkdir -p "$1"
        printf '{"enabled":true,"sha_pinning_required":%s}\n' "$2" > "$1/permissions.json"
        printf '[{"id":1,"name":"tags","target":"tag","enforcement":"%s"},{"id":2,"name":"main","target":"branch","enforcement":"active"}]\n' "$3" > "$1/rulesets.json"
        ruleset_json 1 tag "$3" 'refs/tags/v*' "$4" > "$1/ruleset-1.json"
        ruleset_json 2 branch active '~DEFAULT_BRANCH' "$5" > "$1/ruleset-2.json"
    }
    TAG_OK="creation update deletion"
    BRANCH_OK="deletion non_fast_forward required_status_checks pull_request required_signatures"

    expect() { # expect <pass|fail> <name> <fixture dir>
        local want="$1" name="$2" dir="$3" got=0
        bash "$SCRIPT" --fixtures "$dir" >/dev/null 2>&1 || got=$?
        if [ "$want" = pass ] && [ "$got" -eq 0 ]; then echo "ok   $name"
        elif [ "$want" = fail ] && [ "$got" -eq 1 ]; then echo "ok   $name"
        else echo "FAIL $name (want $want, exit $got)"; bad=$((bad + 1)); fi
    }

    make_set "$d/pass" true active "$TAG_OK" "$BRANCH_OK"
    expect pass "all settings hold" "$d/pass"

    make_set "$d/sha" false active "$TAG_OK" "$BRANCH_OK"
    expect fail "sha_pinning_required false" "$d/sha"

    make_set "$d/tag" true active "creation update" "$BRANCH_OK"
    expect fail "tag ruleset lacks the deletion rule" "$d/tag"

    make_set "$d/branch" true active "$TAG_OK" "deletion non_fast_forward required_status_checks pull_request"
    expect fail "branch ruleset lacks required_signatures" "$d/branch"

    make_set "$d/disabled" true disabled "$TAG_OK" "$BRANCH_OK"
    expect fail "tag ruleset not active" "$d/disabled"

    if [ "$bad" -ne 0 ]; then
        echo "check-repo-settings self-test: $bad failure(s)" >&2
        return 1
    fi
    echo "check-repo-settings self-test: OK"
}

if [ "$MODE" = "self-test" ]; then
    self_test
    exit $?
fi

check
if [ "$fail" -ne 0 ]; then
    echo "check-repo-settings: FAILED" >&2
    exit 1
fi
echo "check-repo-settings: OK ($REPO: sha pinning required, tag ruleset, default-branch ruleset)"
