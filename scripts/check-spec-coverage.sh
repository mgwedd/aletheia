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
checks, journeys, heading = [], collections.OrderedDict(), None
for line in open(AC, encoding="utf-8"):
    h = re.match(r"## \d+\. .*\(([A-Z]+)\)\s*$", line)
    if h:
        journeys.setdefault(h.group(1), [])
        heading = h.group(1)
    m = re.match(r"- \*\*([A-Z]+-\d{2})\*\* (.*)", line.rstrip())
    if not m:
        if line.startswith("- **"):
            errs.append(f"malformed check line (want '- **ID-NN** do → see'): {line.strip()[:60]}")
        continue
    cid, body = m.groups()
    if cid.split("-")[0] != heading:
        errs.append(f"{cid}: sits under the ({heading}) heading")
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
    if not ev:
        errs.append(f"{rid}: no evidence: tag")
        continue
    prev = None
    for tok in (s.strip() for s in ev.group(1).split(",")):
        mm = re.fullmatch(r"([\w./+@-]+)(?::(\d+)(?:-(\d+))?)?", tok)
        bare = re.fullmatch(r"(\d+)(?:-(\d+))?", tok)
        if bare and prev:
            path_s, lo, hi = prev, bare.group(1), bare.group(2)
        elif mm:
            path_s, lo, hi = mm.group(1), mm.group(2), mm.group(3)
            prev = path_s
        else:
            errs.append(f"{rid}: evidence '{tok}' is not a path or path:line")
            continue
        path = os.path.join(root, path_s)
        if os.path.isdir(path) and not lo:
            continue
        if not os.path.isfile(path):
            errs.append(f"{rid}: evidence {path_s} no longer exists")
        elif lo:
            src = open(path, errors="ignore").read().splitlines()
            if int(hi or lo) > len(src):
                errs.append(f"{rid}: evidence {tok} is past the end ({len(src)} lines)")
            elif src[int(lo) - 1].strip() in ("", "{", "}", "})", "]", ")"):
                errs.append(f"{rid}: evidence {path_s}:{lo} is a blank or closing line; it has drifted")
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
    printf 'x\n\n}\ny\n' > "$t/src/B.swift"
    cat > "$t/docs/spec/ACCEPTANCE-CRITERIA.md" <<'MD'
## 1. Demo (DEMO)
- **DEMO-01** Click Go → it goes.
- **DEMO-02** Click Stop → it stops.
- **DEMO-03** Click Go. Then click Stop. Then wait for it → nothing in `Sources/A.swift` happens at all, ever, really, not even once, not later, not tomorrow, not next week, and not on any other day.
- **DEMO-01** Click Again → it repeats.
- **DEMO-04** Click Go and see nothing.
- **DEMO-05** Click Go → it says "one two three four five six seven" aloud.
- **DEMO-9** Click Go → it goes.
- **OTHER-01** Click Go → it goes.
MD
    cat > "$t/docs/spec/BEHAVIOR-REFERENCE.md" <<'MD'
- **DEM-001** Go goes.
  `surface: ui` · `evidence: src/A.swift:2` · `qa: DEMO-01`
- **DEM-002** Moved.
  `surface: ui` · `evidence: src/Gone.swift:1, src/A.swift:9` · `qa: DEMO-03`
- **DEM-003** Stray.
  `surface: ui` · `evidence: src/A.swift` · `qa: DEMO-99`
- **DEM-004** Untagged.
  `surface: ui` · `evidence: src/A.swift:1`
- **DEM-005** Twice.
  `surface: ui` · `evidence: src/A.swift:1` · `qa: DEMO-01`
- **DEM-005** Twice again.
  `surface: ui` · `evidence: src/A.swift:1` · `qa: DEMO-01`
- **DEM-006** No evidence.
  `surface: ui` · `qa: DEMO-01`
- **DEM-007** Drifted.
  `surface: ui` · `evidence: src/B.swift:2, src/B.swift:3, src/A.swift:1, 2-9` · `qa: DEMO-01`
- **DEM-008** Odd refs.
  `surface: ui` · `evidence: Root.txt, see notes` · `qa: DEMO-01`
- **DEM-009** Dir and root ok.
  `surface: ui` · `evidence: src, README.md` · `qa: DEMO-01`
MD
    : > "$t/README.md"
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
        'DEMO-04: needs exactly one' 'DEMO-05: quote over 6 words' 'malformed check line.*DEMO-9' \
        'OTHER-01: sits under the .DEMO. heading' 'DEM-004: no qa: tag' 'DEM-005: duplicate reference ID' \
        'DEM-006: no evidence: tag' 'DEM-007: evidence src/B.swift:2 is a blank' \
        'DEM-007: evidence src/B.swift:3 is a blank' 'DEM-007: evidence 2-9 is past the end' \
        'DEM-008: evidence Root.txt no longer exists' "DEM-008: evidence 'see notes' is not a path" \
        '^DEMO .* 5 .* 2 .* 1 .* 3$'; do
        echo "$out" | grep -qE "$want" || { echo "self-test: not flagged: $want"; echo "$out"; exit 1; }
    done
    echo "$out" | grep -qE 'DEM-001|DEM-009|Copy\.used|DEMO-01: no test' && { echo "self-test: clean item flagged"; echo "$out"; exit 1; }
    rm -rf "$t/Tests"
    { check "$t" || true; } | grep -q 'acceptance suite not started' || { echo "self-test: missing suite not reported"; exit 1; }
    echo "spec coverage gate self-test passed"; exit 0
fi

if check .; then echo "spec coverage OK"; else exit 1; fi
