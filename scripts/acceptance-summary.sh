#!/usr/bin/env bash
# Per-journey pass / fail / pending table for an AletheiaAcceptance result bundle,
# in Markdown (for $GITHUB_STEP_SUMMARY). Lists each failing check with its message.
#
# Usage: scripts/acceptance-summary.sh <TestResults.xcresult>
set -euo pipefail
xcrun xcresulttool get test-results tests --path "$1" | python3 -I -c "$(cat <<'PY'
import collections, json, re, sys

data = json.load(sys.stdin)
rows = collections.OrderedDict()
failures = []

def walk(node):
    if node.get("nodeType") == "Test Case":
        m = re.match(r"test_([A-Z]+)_(\d{2})", node["name"])
        if m:
            rows.setdefault(m.group(1), collections.Counter())[node.get("result", "Unknown")] += 1
            if node.get("result") == "Failed":
                msgs = [c["name"] for c in node.get("children", []) if c.get("nodeType") == "Failure Message"]
                failures.append((f"{m.group(1)}-{m.group(2)}", msgs[0] if msgs else ""))
    for child in node.get("children", []):
        walk(child)

for n in data.get("testNodes", []):
    walk(n)

print("### Acceptance suite\n")
print("| Journey | Passed | Failed | Pending |")
print("|---|---:|---:|---:|")
tot = collections.Counter()
for j, c in rows.items():
    p, f, s = c["Passed"], c["Failed"], c["Skipped"]
    tot.update({"p": p, "f": f, "s": s})
    print(f"| {j} | {p} | {f} | {s} |")
print(f"| **Total** | **{tot['p']}** | **{tot['f']}** | **{tot['s']}** |")
if failures:
    print("\n#### Failing checks\n")
    for cid, msg in failures:
        first = msg.splitlines()[0] if msg else ""
        print(f"- `{cid}` {first}")
PY
)"
