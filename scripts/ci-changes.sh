#!/usr/bin/env bash
# Decides whether an expensive macOS CI job is relevant to a change.
#
# Usage: scripts/ci-changes.sh <benchmarks|package> [BASE_REF [HEAD_REF]]
#
# Prints `true` or `false` on stdout. Without BASE_REF (push, manual dispatch)
# it prints `true`: those events always run. With BASE_REF it lists the files
# changed between BASE_REF and HEAD_REF (default HEAD) and prints `true` when
# any matches that area's path patterns below.
#
# Why a script and not `on.paths`: a workflow skipped by a path filter never
# reports its check, so a required check would stay pending forever. A job
# skipped by a job-level `if:` reports success instead. The workflows run this
# in a small Ubuntu `changes` job and gate the macOS job on its output.
# scripts/check-ci-gating.sh asserts that wiring and tests the patterns here.
#
# Fails closed: if the diff can't be computed, it prints `true` (run the job).

set -euo pipefail
cd "$(dirname "$0")/.."

area="${1:-}"
base="${2:-}"
head="${3:-HEAD}"

case "$area" in
    # Search, index and transcript-compactor sources and their tests, plus the
    # benchmark workflow and its scripts.
    benchmarks)
        pattern='^(Sources/App/Services/Search/|Sources/App/Services/TextSearch\.swift$|Sources/App/Services/TranscriptCompactor\.swift$|Tests/AletheiaTests/[A-Za-z]*(Search|Benchmark|TranscriptCompactor)[A-Za-z]*\.swift$|\.github/workflows/bench\.yml$|scripts/bench-[^/]*$|scripts/ci-changes\.sh$|project\.yml$)'
        ;;
    # What changes the packaged app: project definition, packages, entitlements,
    # Info.plist and other resources, the CD/release workflows, and the scripts
    # packaging calls.
    package)
        pattern='^(project\.yml$|Packages/|Sources/App/Resources/|\.github/workflows/(cd|release)\.yml$|scripts/(build|apply-release|compute-release|changelog-section|ci-changes|launch-smoke|release-notes)\.sh$)'
        ;;
    *)
        echo "usage: $0 <benchmarks|package> [BASE_REF [HEAD_REF]]" >&2
        exit 2
        ;;
esac

if [ -z "$base" ]; then
    echo true
    exit 0
fi

if ! files="$(git diff --name-only "$base" "$head" -- 2>/dev/null)"; then
    echo "ci-changes: could not diff $base..$head; running the job" >&2
    echo true
    exit 0
fi

if grep -Eq "$pattern" <<<"$files"; then
    echo true
else
    echo false
fi
