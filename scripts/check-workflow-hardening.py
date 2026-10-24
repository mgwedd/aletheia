#!/usr/bin/env python3
"""Workflow hardening rules, run by scripts/check-ci-gating.sh.

  - every workflow declares a top-level `permissions:`
  - every actions/checkout sets `persist-credentials: false`, except in the
    workflows allowed to push; `git push` anywhere else is refused
  - release.yml: no `brew install`; build tools are installed before the
    signing certificate is imported; the unsigned-release override fails a tag;
    the built app is checked with check-entitlements.sh --app after the
    signature check; build provenance is attested with a SHA-pinned action and
    the attestation permissions sit on the release job only
  - cd.yml (which produces downloadable DMGs) restores no package cache
  - scripts/build.sh does not `brew install`

Usage: check-workflow-hardening.py [--dir DIR] [--build-script FILE] | --self-test
"""
import glob, os, re, sys, tempfile
import yaml

PUSHING = {"auto-release.yml"}      # these check out with credentials to push a tag
SHA_PIN = re.compile(r"actions/[A-Za-z0-9_.-]+@[0-9a-f]{40}")


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def steps_of(job):
    return job.get("steps") or []


def check(wf_dir, build_script):
    problems = []
    bad = problems.append
    for path in sorted(glob.glob(os.path.join(wf_dir, "*.yml"))):
        name = os.path.basename(path)
        wf = load(path)
        if "permissions" not in wf:
            bad(f"{name}: needs a top-level `permissions:` block")
        for jname, job in (wf.get("jobs") or {}).items():
            for step in steps_of(job):
                uses = str(step.get("uses", ""))
                if uses.startswith("actions/checkout@") and name not in PUSHING:
                    if (step.get("with") or {}).get("persist-credentials") is not False:
                        bad(f"{name}: job {jname}: actions/checkout must set persist-credentials: false")
                if name not in PUSHING and "git push" in str(step.get("run", "")):
                    bad(f"{name}: job {jname}: only {sorted(PUSHING)} may push; add the workflow to the allow-list on purpose")
            if name != "release.yml":
                perms = job.get("permissions") or {}
                if any(k in perms for k in ("id-token", "attestations")):
                    bad(f"{name}: job {jname}: id-token/attestations permissions belong to the release job only")
        top = wf.get("permissions") or {}
        if isinstance(top, dict) and any(k in top for k in ("id-token", "attestations")):
            bad(f"{name}: id-token/attestations must not be granted workflow-wide")

    cd = os.path.join(wf_dir, "cd.yml")
    if os.path.exists(cd):
        for jname, job in (load(cd).get("jobs") or {}).items():
            if any(str(s.get("uses", "")).startswith("actions/cache@") for s in steps_of(job)):
                bad(f"cd.yml: job {jname}: no package cache in the workflow that builds downloadable DMGs")

    rel = os.path.join(wf_dir, "release.yml")
    if os.path.exists(rel):
        wf = load(rel)
        job = wf["jobs"]["release"]
        steps = steps_of(job)
        names = [s.get("name", "") for s in steps]
        runs = [str(s.get("run", "")) for s in steps]
        if any(re.search(r"\bbrew\s+install\b", r) for r in runs):
            bad("release.yml: no `brew install` (tools come from scripts/tools.lock)")
        imp = next((i for i, r in enumerate(runs) if "security import" in r), None)
        inst = next((i for i, r in enumerate(runs) if "install-xcodegen.sh" in r), None)
        build = next((i for i, r in enumerate(runs) if "scripts/build.sh" in r), None)
        if imp is None:
            bad("release.yml: missing the certificate import step")
        if inst is None:
            bad("release.yml: missing the pinned XcodeGen install (scripts/install-xcodegen.sh)")
        if imp is not None and inst is not None and inst > imp:
            bad("release.yml: install build tools before importing the signing certificate")
        if imp is not None and build is not None and "install-xcodegen.sh" not in runs[build] and inst is None:
            bad("release.yml: the build must not install tools after the certificate import")

        # the unsigned-release override fails a tag; nothing else reads it
        guard = [s for s in steps if "vars.ALLOW_UNSIGNED_RELEASE" in str(s.get("if", ""))]
        if len(guard) != 1 or "IS_TAG" not in str(guard[0].get("if", "")) or "exit 1" not in str(guard[0].get("run", "")):
            bad("release.yml: a tag must fail while vars.ALLOW_UNSIGNED_RELEASE is set (one guard step, `exit 1`)")
        for s in steps:
            if s is not (guard[0] if guard else None) and "ALLOW_UNSIGNED_RELEASE" in str(s.get("run", "")) + str(s.get("env", "")):
                bad("release.yml: ALLOW_UNSIGNED_RELEASE must not bypass any other step")

        verify = next((i for i, n in enumerate(names) if n == "Verify Developer ID signature"), None)
        app = next((i for i, r in enumerate(runs) if "check-entitlements.sh --app" in r), None)
        pack = next((i for i, n in enumerate(names) if n == "Package DMG and appcast"), None)
        if app is None:
            bad("release.yml: missing `check-entitlements.sh --app` on the built app")
        elif verify is None or app < verify or (pack is not None and app > pack):
            bad("release.yml: check-entitlements.sh --app must run after the signature check and before packaging")

        att = [s for s in steps if str(s.get("uses", "")).startswith("actions/attest-build-provenance@")]
        if len(att) != 1:
            bad("release.yml: needs exactly one actions/attest-build-provenance step")
        elif not SHA_PIN.fullmatch(att[0]["uses"].split(" ")[0]):
            bad("release.yml: pin actions/attest-build-provenance to a full commit SHA")
        # the SBOM is generated, uploaded with the release, and attested
        sbom = next((i for i, r in enumerate(runs) if "scripts/sbom.sh" in r), None)
        if sbom is None:
            bad("release.yml: missing the SBOM step (scripts/sbom.sh)")
        else:
            sid = steps[sbom].get("id")
            ref = "steps.%s.outputs" % sid if sid else None
            if not sid:
                bad("release.yml: the SBOM step needs an id so later steps can use its output")
            elif not any(ref in str(s.get("run", "")) and "gh release create" in str(s.get("run", "")) for s in steps):
                bad("release.yml: gh release create must upload the SBOM")
            if len(att) == 1 and sid and ref not in str((att[0].get("with") or {}).get("subject-path", "")):
                bad("release.yml: the provenance attestation must include the SBOM")
        perms = job.get("permissions") or {}
        if perms.get("id-token") != "write" or perms.get("attestations") != "write":
            bad("release.yml: the release job needs id-token: write and attestations: write")

    if os.path.exists(build_script):
        if re.search(r"^\s*brew\s+install\b", open(build_script).read(), re.M):
            bad("scripts/build.sh: no `brew install` (use scripts/install-xcodegen.sh)")
    return problems


# ---- self-test: a clean set of workflows, then one break per rule ----------
def good_set():
    co_ok = {"uses": "actions/checkout@" + "a" * 40, "with": {"persist-credentials": False}}
    release = {"name": "Release", "on": {"push": {"tags": ["v*"]}}, "permissions": {"contents": "read"},
               "jobs": {"release": {"permissions": {"contents": "write", "id-token": "write", "attestations": "write"},
                                    "steps": [
        co_ok,
        {"name": "Refuse", "if": "env.IS_TAG == 'true' && vars.ALLOW_UNSIGNED_RELEASE != ''", "run": "exit 1"},
        {"name": "Install XcodeGen (pinned)", "run": "./scripts/install-xcodegen.sh --dest x"},
        {"name": "Import", "run": "security import cert"},
        {"name": "Build Release app", "run": "./scripts/build.sh"},
        {"name": "Verify Developer ID signature", "run": "codesign --verify"},
        {"name": "Check the built app against production", "run": "./scripts/check-entitlements.sh --app dist/Aletheia.app"},
        {"name": "Package DMG and appcast", "run": "hdiutil"},
        {"name": "Generate the SBOM", "id": "sbom", "run": "./scripts/sbom.sh dist/x.json"},
        {"uses": "actions/attest-build-provenance@" + "b" * 40 + " # v4",
         "with": {"subject-path": "x\n${{ steps.sbom.outputs.path }}"}},
        {"name": "Create GitHub Release", "run": "gh release create v1 dist/a.dmg \"${{ steps.sbom.outputs.path }}\""},
    ]}}}
    cd = {"name": "CD", "on": "push", "permissions": {"contents": "read"},
          "jobs": {"package": {"steps": [co_ok, {"run": "./scripts/build.sh"}]}}}
    auto = {"name": "Auto", "on": "push", "permissions": {"contents": "write"},
            "jobs": {"release": {"steps": [{"uses": "actions/checkout@" + "a" * 40}, {"run": "git push origin HEAD:main"}]}}}
    return {"release.yml": release, "cd.yml": cd, "auto-release.yml": auto}


def self_test():
    import copy
    ok = True
    def run(mutate, want):
        nonlocal ok
        wfs = copy.deepcopy(good_set())
        build = "#!/bin/bash\necho build\n"
        out = mutate(wfs, build)
        build = out if isinstance(out, str) else build
        with tempfile.TemporaryDirectory() as d:
            for n, wf in wfs.items():
                with open(os.path.join(d, n), "w") as f:
                    yaml.safe_dump(wf, f, sort_keys=False)
            bs = os.path.join(d, "build.sh")
            open(bs, "w").write(build)
            got = check(d, bs)
        hit = any(want in p for p in got)
        if want is None and got or want is not None and not hit:
            print(f"check-workflow-hardening: self-test: want {want!r}, got {got}", file=sys.stderr)
            ok = False
    steps = lambda w: w["release.yml"]["jobs"]["release"]["steps"]
    run(lambda w, b: None, None)
    run(lambda w, b: w["cd.yml"].pop("permissions"), "top-level `permissions:`")
    run(lambda w, b: w["cd.yml"]["jobs"]["package"]["steps"][0].pop("with"), "persist-credentials")
    run(lambda w, b: w["cd.yml"]["jobs"]["package"]["steps"].append({"run": "git push origin x"}), "may push")
    run(lambda w, b: w["cd.yml"]["jobs"]["package"]["steps"].append({"uses": "actions/cache@" + "c" * 40}), "no package cache")
    run(lambda w, b: steps(w)[3].update(run="brew install xcodegen\nsecurity import cert"), "brew install")
    run(lambda w, b: steps(w).insert(3, steps(w).pop(2)), "before importing the signing certificate")
    run(lambda w, b: steps(w).pop(2), "pinned XcodeGen install")
    run(lambda w, b: steps(w).pop(1), "ALLOW_UNSIGNED_RELEASE is set")
    run(lambda w, b: steps(w)[1].update({"if": "vars.ALLOW_UNSIGNED_RELEASE != 'true'"}), "ALLOW_UNSIGNED_RELEASE is set")
    run(lambda w, b: steps(w).pop(6), "--app")
    run(lambda w, b: steps(w).insert(5, steps(w).pop(6)), "after the signature check")
    run(lambda w, b: steps(w).pop(9), "attest-build-provenance step")
    run(lambda w, b: steps(w).pop(8), "missing the SBOM step")
    run(lambda w, b: steps(w).pop(10), "must upload the SBOM")
    run(lambda w, b: steps(w)[10].update(run="gh release create v1 dist/a.dmg"), "must upload the SBOM")
    run(lambda w, b: steps(w)[9]["with"].update({"subject-path": "x"}), "attestation must include the SBOM")
    run(lambda w, b: steps(w)[8].pop("id"), "needs an id")
    run(lambda w, b: steps(w)[9].update(uses="actions/attest-build-provenance@v4"), "full commit SHA")
    run(lambda w, b: w["release.yml"]["jobs"]["release"].pop("permissions"), "id-token: write")
    run(lambda w, b: w["cd.yml"]["jobs"]["package"].update(permissions={"id-token": "write"}), "release job only")
    run(lambda w, b: "brew install xcodegen\n", "scripts/build.sh")
    if not ok:
        return 1
    print("check-workflow-hardening: self-test OK")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args == ["--self-test"]:
        sys.exit(self_test())
    wf_dir = args[args.index("--dir") + 1] if "--dir" in args else ".github/workflows"
    bs = args[args.index("--build-script") + 1] if "--build-script" in args else "scripts/build.sh"
    probs = check(wf_dir, bs)
    for p in probs:
        print(f"check-workflow-hardening: {p}", file=sys.stderr)
    sys.exit(1 if probs else 0)
