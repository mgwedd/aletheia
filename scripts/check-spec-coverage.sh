#!/usr/bin/env bash
# Spec coverage gate: the acceptance pyramid can't drift layer from layer.
#
#   ACCEPTANCE-CRITERIA.md  QA walkthrough: short "do X → see Y" lines, unique IDs
#        ▲ qa: tags
#   BEHAVIOR-REFERENCE.md   every item rolls up to a real check; every check has
#                           at least one item; evidence paths and lines exist
#        ▲ test_<ID>
#   Tests/AletheiaAcceptance one fitness function per check, no strays or
#                           duplicates, no XCTExpectFailure, every Copy entry used
#
# Fitness functions assert the intended behavior, so a red one is an honest
# result, not something to mask. Until Tests/AletheiaAcceptance exists the
# test checks are skipped.
#
# Usage: scripts/check-spec-coverage.sh [--self-test]   (from anywhere)

set -euo pipefail
cd "$(dirname "$0")/.."

# check <repo-root>; prints problems and a per-journey table, returns 1 on any problem.
check() {
    python3 -I - "$1" <<'PY'
import collections, os, re, sys

root = sys.argv[1]
AC = os.path.join(root, "docs/spec/ACCEPTANCE-CRITERIA.md")
REF = os.path.join(root, "docs/spec/BEHAVIOR-REFERENCE.md")
SUITE = os.path.join(root, "Tests/AletheiaAcceptance")
errs = []

# Walkthrough: one short action → outcome line per check.
checks, journeys = [], collections.OrderedDict()
for line in open(AC, encoding="utf-8"):
    h = re.match(r"## \d+\. .*\(([A-Z]+)\)\s*$", line)
    if h:
        journeys.setdefault(h.group(1), [])
    m = re.match(r"- \*\*([A-Z]+-\d{2})\*\* (.*)", line.rstrip())
    if not m:
        continue
    cid, body = m.groups()
    build = cid.startswith("BUILD-")
    checks.append(cid)
    j = journeys.setdefault(cid.split("-")[0], [])
    if cid not in j:
        j.append(cid)
    words = len(body.split())
    if words > (40 if build else 30):
        errs.append(f"{cid}: {words} words (max {40 if build else 30})")
    if body.count("→") != 1:
        errs.append(f"{cid}: needs exactly one →")
    if re.search(r"\bThen\b", body):
        errs.append(f'{cid}: chained "Then"; split the check or trim it')
    for a, b in re.findall(r'"([^"]*)"|“([^”]*)”', body):
        if len((a or b).split()) > 6:
            errs.append(f"{cid}: quote over 6 words; put exact copy in the reference")
    if not build and re.search(r"Sources/|\.swift|`", body):
        errs.append(f"{cid}: names code; keep the walkthrough in product words")
for cid, n in collections.Counter(checks).items():
    if n > 1:
        errs.append(f"{cid}: duplicate check ID")
known = set(checks)

# Reference: every item rolls up to a check; evidence still points at real lines.
items, rolled = collections.Counter(), set()
lines = open(REF, encoding="utf-8").read().splitlines()
for i, line in enumerate(lines):
    m = re.match(r"- \*\*([A-Z]+-\d{3})\*\* ", line)
    if not m:
        continue
    rid = m.group(1)
    items[rid] += 1
    tags = lines[i + 1] if i + 1 < len(lines) else ""
    q = re.search(r"`qa: ([A-Z]+-\d{2})`", tags)
    if not q:
        errs.append(f"{rid}: no qa: tag")
    elif q.group(1) not in known:
        errs.append(f"{rid}: qa: {q.group(1)} is not a check in the walkthrough")
    else:
        rolled.add(q.group(1))
    ev = re.search(r"`evidence: ([^`]*)`", tags)
    for ref in re.split(r",\s*", ev.group(1)) if ev else []:
        mm = re.match(r"([\w./+-]+\.\w+)(?::(\d+)(?:-(\d+))?)?", ref.strip())
        if not mm or "/" not in mm.group(1):
            continue
        path = os.path.join(root, mm.group(1))
        if not os.path.isfile(path):
            errs.append(f"{rid}: evidence {mm.group(1)} no longer exists")
        elif mm.group(2):
            n = sum(1 for _ in open(path, errors="ignore"))
            if int(mm.group(3) or mm.group(2)) > n:
                errs.append(f"{rid}: evidence {ref.strip()} is past the end ({n} lines)")
for rid, n in items.items():
    if n > 1:
        errs.append(f"{rid}: duplicate reference ID")
for cid in checks:
    if cid not in rolled:
        errs.append(f"{cid}: no reference item rolls up to it")

# Fitness functions: one per check, intended behavior only.
tests, pending = collections.Counter(), set()
suite = os.path.isdir(SUITE)
if suite:
    copy_file, sources = None, {}
    for d, _, fs in os.walk(SUITE):
        for f in fs:
            if f.endswith(".swift"):
                p = os.path.join(d, f)
                sources[p] = open(p, encoding="utf-8").read()
                if f == "Copy.swift":
                    copy_file = p
    for p, text in sources.items():
        rel = os.path.relpath(p, root)
        if "XCTExpectFailure" in text:
            errs.append(f"{rel}: XCTExpectFailure; let a known defect fail")
        parts = re.split(r"(?=\bfunc test_)", text)
        for part in parts[1:]:
            t = re.match(r"func test_([A-Z]+)_(\d{2})\b", part)
            if not t:
                continue
            cid = f"{t.group(1)}-{t.group(2)}"
            tests[cid] += 1
            if re.search(r"\bpending\(", part):
                pending.add(cid)
            if cid not in known:
                errs.append(f"{rel}: test_{cid.replace('-', '_')} has no check in the walkthrough")
    for cid, n in tests.items():
        if n > 1:
            errs.append(f"test_{cid.replace('-', '_')}: defined {n} times")
    for cid in checks:
        if cid not in tests:
            errs.append(f"{cid}: no test_{cid.replace('-', '_')}")
    if copy_file:
        rest = "".join(t for p, t in sources.items() if p != copy_file)
        for name in re.findall(r"static let (\w+)", sources[copy_file]):
            if not re.search(rf"\bCopy\.{name}\b", rest):
                errs.append(f"Copy.{name} is used by no test")

print(f"{'journey':<10} {'checks':>6} {'tests':>6} {'pending':>7} {'missing':>7}")
for j, ids in journeys.items():
    have = [c for c in ids if c in tests]
    print(f"{j:<10} {len(ids):>6} {len(have):>6} {len([c for c in have if c in pending]):>7} "
          f"{len(ids) - len(have):>7}")
print(f"{len(checks)} checks, {sum(items.values())} reference items, {len(tests)} tests"
      + ("" if suite else " (acceptance suite not started; test checks skipped)"))
for e in errs:
    print(e)
sys.exit(1 if errs else 0)
PY
}

if [ "${1:-}" = "--self-test" ]; then
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    mkdir -p "$t/docs/spec" "$t/src" "$t/Tests/AletheiaAcceptance/DSL"
    printf 'a\nb\nc\n' > "$t/src/A.swift"
    cat > "$t/docs/spec/ACCEPTANCE-CRITERIA.md" <<'MD'
## 1. Demo (DEMO)
- **DEMO-01** Click Go → it goes.
- **DEMO-02** Click Stop → it stops.
- **DEMO-03** Click Go. Then click Stop. Then wait for it → nothing in `Sources/A.swift` happens at all, ever, really, not even once, not later, not tomorrow, not next week, and not on any other day.
- **DEMO-01** Click Again → it repeats.
MD
    cat > "$t/docs/spec/BEHAVIOR-REFERENCE.md" <<'MD'
- **DEM-001** Go goes.
  `surface: ui` · `evidence: src/A.swift:2` · `qa: DEMO-01`
- **DEM-002** Moved.
  `surface: ui` · `evidence: src/Gone.swift:1, src/A.swift:9` · `qa: DEMO-03`
- **DEM-003** Stray.
  `surface: ui` · `evidence: src/A.swift` · `qa: DEMO-99`
MD
    cat > "$t/Tests/AletheiaAcceptance/DSL/Copy.swift" <<'SW'
enum Copy { static let used = "a"; static let unused = "b" }
SW
    cat > "$t/Tests/AletheiaAcceptance/DemoSpec.swift" <<'SW'
func test_DEMO_01() { _ = Copy.used }
func test_DEMO_03() { try pending("later") }
func test_DEMO_03() { XCTExpectFailure("known") }
func test_DEMO_77() {}
SW
    out=$(check "$t" || true)
    for want in 'DEMO-01: duplicate check ID' 'DEMO-03: .* words' 'DEMO-03: chained' \
        'DEMO-03: names code' 'DEM-002: evidence src/Gone.swift no longer exists' \
        'DEM-002: evidence src/A.swift:9 is past the end' 'DEM-003: qa: DEMO-99 is not a check' \
        'DEMO-02: no reference item' 'DEMO-02: no test_DEMO_02' 'test_DEMO_03: defined 2 times' \
        'test_DEMO_77 has no check' 'XCTExpectFailure' 'Copy.unused is used by no test' \
        '^DEMO .* 3 .* 2 .* 1 .* 1$'; do
        echo "$out" | grep -qE "$want" || { echo "self-test: not flagged: $want"; echo "$out"; exit 1; }
    done
    echo "$out" | grep -qE 'DEM-001|Copy\.used|DEMO-01: no test' && { echo "self-test: clean item flagged"; echo "$out"; exit 1; }
    rm -rf "$t/Tests"
    { check "$t" || true; } | grep -q 'acceptance suite not started' || { echo "self-test: missing suite not reported"; exit 1; }
    echo "spec coverage gate self-test passed"; exit 0
fi

if check .; then echo "spec coverage OK"; else exit 1; fi
