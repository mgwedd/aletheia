#!/usr/bin/env python3
"""Markdown report comparing this run's benchmarks with recent main runs.

Usage: bench-report.py <results.json> <baseline-dir>
       bench-report.py --self-test

results.json is a list of {"name", "unit", "samples"} (the BENCH-JSON lines
PRBenchmarkTests prints). baseline-dir holds one results.json per earlier main
run, in any layout. Each metric's median is compared with the medians of those
runs: more than 3 robust standard deviations (MAD-based, floored at 5% of the
baseline so a quiet history doesn't flag noise) is out of distribution. It only
reports; it never fails the build.
"""
import json
import pathlib
import statistics
import sys

MIN_BASELINES = 5
Z_LIMIT = 3.0


def verdict(value, history):
    if len(history) < MIN_BASELINES:
        return None, f"baseline {len(history)}/{MIN_BASELINES}"
    center = statistics.median(history)
    mad = statistics.median(abs(h - center) for h in history)
    spread = max(1.4826 * mad, 0.05 * center)
    z = (value - center) / spread
    if z > Z_LIMIT:
        return center, f"⚠️ slower (z={z:.1f})"
    if z < -Z_LIMIT:
        return center, f"faster (z={z:.1f})"
    return center, "ok"


def report(current, baselines):
    history = {}
    for run in baselines:
        for m in run:
            history.setdefault(m["name"], []).append(statistics.median(m["samples"]))
    lines = ["| Benchmark | This run | Main median | Change | Verdict |", "|---|---|---|---|---|"]
    flagged = 0
    for m in current:
        value = statistics.median(m["samples"])
        center, text = verdict(value, history.get(m["name"], []))
        flagged += text.startswith("⚠️")
        change = f"{(value / center - 1) * 100:+.0f}%" if center else "–"
        main = f"{center:.1f} {m['unit']}" if center else "–"
        lines.append(f"| `{m['name']}` | {value:.1f} {m['unit']} | {main} | {change} | {text} |")
    runs = len(baselines)
    head = (f"**{flagged} benchmark(s) out of distribution**" if flagged else "No benchmark out of distribution") \
        + f" (median of this run's samples vs. the last {runs} main run(s); informational, never blocks)."
    return head + "\n\n" + "\n".join(lines)


def self_test():
    base = [[{"name": "a", "unit": "ms", "samples": [100 + i]}] for i in range(6)]
    assert verdict(103, [100 + i for i in range(6)])[1] == "ok"
    assert verdict(140, [100 + i for i in range(6)])[1].startswith("⚠️")
    assert verdict(60, [100 + i for i in range(6)])[1].startswith("faster")
    assert verdict(500, [100, 101])[1] == "baseline 2/5"
    out = report([{"name": "a", "unit": "ms", "samples": [150, 160, 155]}], base)
    assert "1 benchmark(s) out of distribution" in out and "+51%" in out, out
    out = report([{"name": "new", "unit": "ms", "samples": [1]}], base)
    assert "No benchmark out of distribution" in out and "baseline 0/5" in out, out
    print("bench-report self-test passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        sys.exit()
    current = json.loads(pathlib.Path(sys.argv[1]).read_text())
    baselines = [json.loads(p.read_text()) for p in sorted(pathlib.Path(sys.argv[2]).rglob("results.json"))]
    print(report(current, baselines))
