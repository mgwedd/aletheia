#!/usr/bin/env bash
# Writes a CycloneDX-style JSON inventory of what the app ships and builds with:
#   frameworks  prebuilt XCFrameworks (URL + checksum) from Packages/*/Package.swift
#   assets      tracked binary model/asset files (sha256 of the bytes)
#   models      downloadable Whisper and LLM models (repo + revision + sha256)
#   actions     every `uses:` reference in .github/workflows (pinned SHA)
#
# Usage:
#   scripts/sbom.sh [outfile]     write to outfile (default: stdout)
#   scripts/sbom.sh --self-test   generate and validate each section
# Needs python3.

set -uo pipefail
cd "$(dirname "$0")/.."

generate() {
  python3 -I - <<'PY'
import datetime, hashlib, json, re, subprocess
from pathlib import Path

def sec(section, **kw):
    kw.setdefault("properties", []).append({"name": "aletheia:section", "value": section})
    return kw

components = []

# frameworks
for pkg in sorted(Path("Packages").glob("*/Package.swift")):
    text = pkg.read_text()
    for m in re.finditer(r'\.binaryTarget\(\s*name:\s*"([^"]+)".*?url:\s*"([^"]+)".*?checksum:\s*"([0-9a-f]+)"', text, re.S):
        name, url, checksum = m.groups()
        ver = re.search(r"/download/([^/]+)/", url)
        components.append(sec("frameworks", type="framework", name=name,
            version=ver.group(1) if ver else "",
            hashes=[{"alg": "SHA-256", "content": checksum}],
            externalReferences=[{"type": "distribution", "url": url}]))

# bundled assets
files = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout.split("\n")
for f in sorted(x for x in files if re.search(r"\.(bin|gguf|onnx|mlmodel[a-z]*|mlpackage|metallib)$", x, re.I)):
    components.append(sec("assets", type="data", name=f,
        hashes=[{"alg": "SHA-256", "content": hashlib.sha256(Path(f).read_bytes()).hexdigest()}]))

# whisper models
pins = Path("Sources/App/Services/WhisperModelPins.swift").read_text()
settings = Path("Sources/App/Services/AppSettings.swift").read_text()
rev = re.search(r'static let revision = "([0-9a-f]{40})"', pins).group(1)
block = re.search(r"var expectedSHA256: String \{(.*?)\n    \}", pins, re.S).group(1)
raw = dict(re.findall(r'^    case (\w+) = "([^"]+)"', settings.split("enum WhisperModel", 1)[1].split("\n}", 1)[0], re.M))
for case, sha in re.findall(r'case \.(\w+): return "([0-9a-f]{64})"', block):
    components.append(sec("models", type="machine-learning-model", name="ggerganov/whisper.cpp:ggml-%s.bin" % raw.get(case, case),
        version=rev, hashes=[{"alg": "SHA-256", "content": sha}],
        externalReferences=[{"type": "distribution", "url": "https://huggingface.co/ggerganov/whisper.cpp/tree/" + rev}]))

# llm models
llama = Path("Sources/App/Services/Llama/LlamaModel.swift").read_text()
def prop(name):
    m = re.search(r"var %s: \w+ \{(.*?)\n    \}" % name, llama, re.S)
    return dict(re.findall(r'case \.(\w+): return "([^"]+)"', m.group(1)))
repo, revs, shas, fnames = prop("repo"), prop("revision"), prop("expectedSHA256"), prop("fileName")
for case in sorted(shas):
    r = repo[case] if "/" in repo[case] else "ggml-org/" + repo[case]
    components.append(sec("models", type="machine-learning-model", name="%s:%s" % (r, fnames[case]),
        version=revs[case], hashes=[{"alg": "SHA-256", "content": shas[case]}],
        externalReferences=[{"type": "distribution", "url": "https://huggingface.co/%s/tree/%s" % (r, revs[case])}]))

# workflow actions
seen = {}
for wf in sorted(Path(".github/workflows").glob("*.y*ml")):
    for line in wf.read_text().splitlines():
        m = re.match(r"\s*-?\s*uses:\s*([^@\s]+)@(\S+)(?:\s*#\s*(\S+))?", line)
        if m:
            seen[(m.group(1), m.group(2))] = m.group(3) or ""
for (name, ref), ver in sorted(seen.items()):
    components.append(sec("actions", type="library", name=name, version=ref,
        purl="pkg:github/%s@%s" % (name, ref),
        properties=[{"name": "aletheia:tag", "value": ver}] if ver else []))

print(json.dumps({
    "bomFormat": "CycloneDX", "specVersion": "1.5", "version": 1,
    "metadata": {"timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "component": {"type": "application", "name": "Aletheia"}},
    "components": components}, indent=2))
PY
}

self_test() {
  local out rc
  out=$(mktemp); trap 'rm -f "$out"' RETURN
  generate >"$out" || { echo "FAIL - generator failed" >&2; return 1; }
  python3 -I - "$out" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
assert d["bomFormat"] == "CycloneDX", "bomFormat"
secs = {}
for c in d["components"]:
    s = [p["value"] for p in c["properties"] if p["name"] == "aletheia:section"][0]
    secs.setdefault(s, []).append(c)
for s in ("frameworks", "assets", "models", "actions"):
    assert secs.get(s), "missing section " + s
for c in secs["frameworks"]:
    assert re.fullmatch(r"[0-9a-f]{64}", c["hashes"][0]["content"]) and c["externalReferences"][0]["url"].startswith("https://"), c["name"]
for c in secs["assets"] + secs["models"]:
    assert re.fullmatch(r"[0-9a-f]{64}", c["hashes"][0]["content"]), c["name"]
for c in secs["models"]:
    assert re.fullmatch(r"[0-9a-f]{40}", c["version"]), c["name"]
for c in secs["actions"]:
    assert re.fullmatch(r"[0-9a-f]{40}", c["version"]), "action not SHA-pinned: " + c["name"]
print("self-test passed: " + ", ".join("%s=%d" % (k, len(v)) for k, v in sorted(secs.items())))
PY
}

case "${1:-}" in
  --self-test) self_test; exit $? ;;
  "") generate ;;
  -*) echo "usage: $0 [outfile | --self-test]" >&2; exit 2 ;;
  *) generate >"$1" ;;
esac
