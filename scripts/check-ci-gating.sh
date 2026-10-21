#!/usr/bin/env bash
# Guard for how CI spends macOS runner time (issue #350).
#
# Asserts the intended workflow structure:
#   - smoke-test.yml: only the dev tier runs the full suite; production and
#     preview run a `-only-testing:` subset, and every class in that subset
#     exists under Tests/AletheiaTests.
#   - cd.yml ("Build & package (macOS)") and bench.yml ("Benchmarks
#     (informational)") are gated by a job-level `if:` on an Ubuntu `changes`
#     job's output, with their job names unchanged. Neither workflow uses
#     `on.paths` (a path-filtered workflow never reports its check, so a
#     required check would stay pending forever); cd.yml's long-standing
#     `paths-ignore` is the only filter allowed.
#   - no third-party marketplace actions (only `actions/*`).
# and that scripts/ci-changes.sh maps changed files to the right answer.
#
# Usage: scripts/check-ci-gating.sh [--self-test]
#   --self-test  only run the ci-changes.sh path-pattern tests on a scratch repo.
# Needs python3 with PyYAML (preinstalled on ubuntu-latest); otherwise the
# structure checks are skipped with a warning when run locally.

set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
err() { echo "check-ci-gating: $*" >&2; fail=1; }

# ---- scripts/ci-changes.sh behaviour, on a scratch git repo ----------------
self_test() {
    local repo script
    script="$PWD/scripts/ci-changes.sh"
    repo="$(mktemp -d)"
    trap 'rm -rf "$repo"' RETURN
    (
        cd "$repo"
        git init -q
        git config user.email t@example.com
        git config user.name t
        mkdir -p scripts
        # ci-changes.sh does `cd "$(dirname "$0")/.."`, so run a copy inside the scratch repo.
        cp "$script" scripts/ci-changes.sh
        echo base > README.md
        git add -A && git commit -qm base
    )
    expect() { # expect <area> <true|false> <path>...
        local area="$1" want="$2"; shift 2
        (
            cd "$repo"
            git checkout -q --detach "$(git rev-list --max-parents=0 HEAD)"
            git reset -q --hard
            for f in "$@"; do mkdir -p "$(dirname "$f")"; echo "x$RANDOM" > "$f"; done
            git add -A && git commit -qm change
        )
        local got
        got="$(cd "$repo" && ./scripts/ci-changes.sh "$area" "$(git -C "$repo" rev-list --max-parents=0 HEAD)" HEAD)"
        [ "$got" = "$want" ] || err "ci-changes.sh $area for [$*]: want $want, got $got"
    }
    # benchmarks
    expect benchmarks true  Sources/App/Services/Search/SearchIndex.swift
    expect benchmarks true  Sources/App/Services/TranscriptCompactor.swift
    expect benchmarks true  Sources/App/Services/TextSearch.swift
    expect benchmarks true  Tests/AletheiaTests/SessionSearchTests.swift
    expect benchmarks true  Tests/AletheiaTests/PRBenchmarkTests.swift
    expect benchmarks true  Tests/AletheiaTests/TranscriptCompactorTests.swift
    expect benchmarks true  scripts/bench-report.py
    expect benchmarks true  .github/workflows/bench.yml
    expect benchmarks false Sources/App/Views/SettingsView.swift README.md docs/guide.md
    expect benchmarks false Tests/AletheiaTests/BuildTierTests.swift
    # package
    expect package true  project.yml
    expect package true  Sources/App/Resources/Aletheia.entitlements
    expect package true  Sources/App/Resources/Info.plist
    expect package true  Packages/WhisperCpp/Package.swift
    expect package true  .github/workflows/release.yml
    expect package true  .github/workflows/cd.yml
    expect package true  scripts/build.sh
    expect package true  scripts/launch-smoke.sh
    expect package true  scripts/release-notes.sh
    expect package false Sources/App/Views/SettingsView.swift Tests/AletheiaTests/BuildTierTests.swift
    expect package false docs/SETUP-GUIDE.md .github/workflows/smoke-test.yml
    # no base (push / dispatch) always runs; unknown base fails closed; bad area errors
    [ "$(cd "$repo" && ./scripts/ci-changes.sh package)" = true ] || err "no base ref must print true"
    [ "$(cd "$repo" && ./scripts/ci-changes.sh package deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>/dev/null)" = true ] \
        || err "unresolvable base must fail closed (true)"
    if (cd "$repo" && ./scripts/ci-changes.sh nonsense >/dev/null 2>&1); then err "unknown area must exit non-zero"; fi

    # release-notes.sh: one version's entry, without its heading or the next one.
    local log="$repo/CHANGELOG.md"
    printf '%s\n' '# Changelog' '' '## [1.2.0] - 2026-01-02' '' '### Added' '- new thing (#2)' '' \
        '## [1.1.0] - 2026-01-01' '' '### Fixed' '- old bug (#1)' '' '## [1.0.0] - 2025-12-31' '' > "$log"
    [ "$(scripts/release-notes.sh 1.2.0 "$log")" = "$(printf '### Added\n- new thing (#2)')" ] \
        || err "release-notes.sh 1.2.0: wrong section"
    [ "$(scripts/release-notes.sh v1.1.0 "$log")" = "$(printf '### Fixed\n- old bug (#1)')" ] \
        || err "release-notes.sh v1.1.0: wrong section (or v prefix not stripped)"
    [ "$(scripts/release-notes.sh 1.0.0 "$log")" = "Maintenance release." ] \
        || err "release-notes.sh: an empty entry must say Maintenance release."
    [ "$(scripts/release-notes.sh 9.9.9 "$log")" = "Maintenance release." ] \
        || err "release-notes.sh: a missing entry must say Maintenance release."

    # launch-smoke.sh: passes an app that stays up, fails one that exits.
    scripts/launch-smoke.sh --self-test >/dev/null || err "launch-smoke.sh self-test failed"
}

self_test
if [ "${1:-}" = "--self-test" ]; then
    [ "$fail" -eq 0 ] || { echo "check-ci-gating: FAILED" >&2; exit 1; }
    echo "check-ci-gating: self-test OK"
    exit 0
fi

# ---- workflow structure ------------------------------------------------------
if ! python3 -c 'import yaml' 2>/dev/null; then
    echo "check-ci-gating: PyYAML not available; skipping structure checks" >&2
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

python3 - "$fail" <<'PY' || fail=1
import re, subprocess, sys, yaml

problems = []
def bad(msg): problems.append(msg)

def load(path):
    with open(path) as f:
        return yaml.safe_load(f)

def triggers(wf):
    return wf.get("on", wf.get(True))  # PyYAML parses a bare `on:` as True

# no third-party marketplace actions anywhere, and every first-party action is
# pinned to a full commit SHA (a tag can be moved; Dependabot bumps the pins)
import glob, os
for path in glob.glob(".github/workflows/*.yml"):
    wf = load(path)
    for jname, job in (wf.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            uses = step.get("uses")
            if not uses or uses.startswith("./"):
                continue
            if not uses.startswith("actions/"):
                bad(f"{path}: job {jname} uses third-party action {uses}")
            elif not re.fullmatch(r"actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}", uses):
                bad(f"{path}: job {jname} must pin {uses} to a full commit SHA")
if not os.path.exists(".github/dependabot.yml"):
    bad(".github/dependabot.yml is missing (it keeps the action pins current)")
else:
    eco = [u.get("package-ecosystem") for u in (load(".github/dependabot.yml").get("updates") or [])]
    if "github-actions" not in eco:
        bad(".github/dependabot.yml must update the github-actions ecosystem")

# release.yml: a tag publishes only a notarized build, the packaged app is
# launched first, and the notes come from the version's CHANGELOG entry
release = load(".github/workflows/release.yml")["jobs"]["release"]
rsteps = {s.get("name", ""): s for s in release["steps"]}
guard = rsteps.get("Require a signed, notarized build for a tag")
if guard is None:
    bad("release.yml: missing 'Require a signed, notarized build for a tag'")
else:
    cond, run = str(guard.get("if", "")), guard.get("run", "")
    if "env.IS_TAG == 'true'" not in cond or "vars.ALLOW_UNSIGNED_RELEASE" not in cond:
        bad("release.yml: the signing guard must run on tags unless ALLOW_UNSIGNED_RELEASE is set")
    if "HAS_SIGNING" not in run or "HAS_NOTARIZATION" not in run or "exit 1" not in run:
        bad("release.yml: the signing guard must fail without signing and notarization secrets")
    names = list(rsteps)
    if names.index("Require a signed, notarized build for a tag") > names.index("Build Release app"):
        bad("release.yml: the signing guard must run before the build")
publish = rsteps.get("Create GitHub Release", {})
prun = publish.get("run", "")
if 'NOTARIZED:-false}" != "true"' not in prun or "ALLOW_UNSIGNED_RELEASE" not in prun:
    bad("release.yml: Create GitHub Release must refuse a build that was not notarized")
if "--notes-file" not in prun:
    bad("release.yml: the release body must come from --notes-file (the CHANGELOG entry)")
if "release-notes.sh" not in rsteps.get("Package DMG and appcast", {}).get("run", ""):
    bad("release.yml: the appcast must take its notes from scripts/release-notes.sh")
launch = rsteps.get("Launch the packaged app")
if launch is None or "scripts/launch-smoke.sh" not in launch.get("run", ""):
    bad("release.yml: missing 'Launch the packaged app' (scripts/launch-smoke.sh)")
elif list(rsteps).index("Launch the packaged app") > list(rsteps).index("Create GitHub Release"):
    bad("release.yml: the packaged app must be launched before publishing")
cd_steps = load(".github/workflows/cd.yml")["jobs"]["package"]["steps"]
if not any("scripts/launch-smoke.sh" in s.get("run", "") for s in cd_steps):
    bad("cd.yml: the package job must launch the packaged app (scripts/launch-smoke.sh)")

# smoke-test.yml: tier subset
smoke = load(".github/workflows/smoke-test.yml")
text = open(".github/workflows/smoke-test.yml").read()
job = smoke["jobs"]["build-and-test"]
if job["name"] != "Build & test (${{ matrix.tier }}, ${{ matrix.runner }})":
    bad("smoke-test.yml: build-and-test job name changed")
if "dev" not in job["strategy"]["matrix"]["tier"] or len(job["strategy"]["matrix"]["tier"]) != 3:
    bad("smoke-test.yml: matrix must still build production, preview and dev")
step = next((s for s in job["steps"] if s.get("name", "").startswith("Run unit tests")), None)
if step is None:
    bad("smoke-test.yml: no 'Run unit tests' step")
else:
    run = step["run"]
    if '!= "dev"' not in run:
        bad("smoke-test.yml: the -only-testing subset must be conditional on tier != dev")
    if "${ONLY[@]" not in run:
        bad("smoke-test.yml: the xcodebuild test call must receive the ONLY array")
    classes = re.findall(r"^\s+([A-Za-z]+Tests)(?:;| \\)", run, re.M)
    must = {"BuildTierTests", "FeatureRegistryTests", "AtRestEncryptionFeatureModuleTests"}
    if not must <= set(classes):
        bad(f"smoke-test.yml: subset must include {sorted(must - set(classes))}")
    if "-only-testing:AletheiaTests/$t" not in run:
        bad("smoke-test.yml: subset must use -only-testing:AletheiaTests/<class>")
    all_tests = subprocess.run(["grep", "-rhoE", r"^(final )?class [A-Za-z0-9_]+", "Tests/AletheiaTests"],
                               capture_output=True, text=True).stdout
    known = set(re.findall(r"class ([A-Za-z0-9_]+)", all_tests))
    for c in classes:
        if c not in known:
            bad(f"smoke-test.yml: subset names {c}, which is not a test class under Tests/AletheiaTests")
guard = [s.get("run", "") for s in smoke["jobs"]["entitlements-guard"]["steps"]]
if not any("check-ci-gating.sh" in r and "--self-test" not in r for r in guard):
    bad("smoke-test.yml: entitlements-guard job must run scripts/check-ci-gating.sh")
if not any("check-ci-gating.sh --self-test" in r for r in guard):
    bad("smoke-test.yml: entitlements-guard job must self-test scripts/check-ci-gating.sh")

# cd.yml / bench.yml: changes job + job-level if, names unchanged
def check_gated(path, jobid, jobname, area):
    wf = load(path)
    on = triggers(wf)
    for ev in ("push", "pull_request"):
        if isinstance(on, dict) and isinstance(on.get(ev), dict) and "paths" in on[ev]:
            bad(f"{path}: on.{ev}.paths would leave a required check pending; use the changes job")
    jobs = wf["jobs"]
    ch = jobs.get("changes")
    if not ch:
        bad(f"{path}: missing the `changes` job"); return
    if ch.get("runs-on") != "ubuntu-latest":
        bad(f"{path}: `changes` must run on ubuntu-latest")
    steps = ch.get("steps") or []
    co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    if not co or str(co[0].get("with", {}).get("fetch-depth")) != "0":
        bad(f"{path}: `changes` must use actions/checkout with fetch-depth: 0")
    if not any(f"ci-changes.sh {area}" in s.get("run", "") for s in steps):
        bad(f"{path}: `changes` must call scripts/ci-changes.sh {area}")
    if area not in (ch.get("outputs") or {}):
        bad(f"{path}: `changes` must expose output {area}")
    j = jobs[jobid]
    if j.get("name") != jobname:
        bad(f"{path}: job name must stay {jobname!r}, is {j.get('name')!r}")
    if not j.get("runs-on", "").startswith("macos"):
        bad(f"{path}: {jobid} should still run on macOS")
    if j.get("needs") != "changes" and "changes" not in (j.get("needs") or []):
        bad(f"{path}: {jobid} must need `changes`")
    cond = str(j.get("if", ""))
    if f"needs.changes.outputs.{area} == 'true'" not in cond:
        bad(f"{path}: {jobid} `if:` must test needs.changes.outputs.{area}")
    if "needs.changes.result != 'success'" not in cond:
        bad(f"{path}: {jobid} `if:` must fail open when `changes` fails")
    if "!cancelled()" not in cond:
        bad(f"{path}: {jobid} `if:` must start with !cancelled() so a skipped dependency can't skip it")

check_gated(".github/workflows/cd.yml", "package", "Build & package (macOS)", "package")
check_gated(".github/workflows/bench.yml", "bench", "Benchmarks (informational)", "benchmarks")

for p in problems:
    print(f"check-ci-gating: {p}", file=sys.stderr)
sys.exit(1 if problems else 0)
PY

if [ "$fail" -ne 0 ]; then
    echo "check-ci-gating: FAILED" >&2
    exit 1
fi
echo "check-ci-gating: OK (tier test subsets; package/benchmarks gated by job-level if)"
