#!/usr/bin/env bash
# Renders the synthetic audio fixtures the UI journeys record from.
#
# Every fixture is an invented dialogue in Tests/Fixtures/Audio/<name>.script
# ("T:" = therapist on the microphone track, "C:" = client on the call track,
# "pause N" = N seconds of silence). Speech comes from two stock macOS voices
# through `say`; nothing here reads or copies a real recording.
#
# For each <name> it writes, into the output folder:
#   <name>.mic.caf         the therapist's track
#   <name>.call.caf        the client's track
#   <name>.expected.txt    the transcript the fake speech engine returns, in the
#                          app's "[MM:SS] You: ..." / "Call audio: ..." format
#
# The audio files are Float32 mono CAF at 48 kHz, which is what the recorder
# writes from the microphone's usual input format. They are generated rather
# than committed (scripts/scan-secrets.sh refuses audio files in git).
#
# Usage: scripts/make-audio-fixtures.sh <output-folder>

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: make-audio-fixtures.sh <output-folder>}"
SRC="Tests/Fixtures/Audio"
THERAPIST_VOICE="Samantha"
CLIENT_VOICE="Daniel"
RATE=48000

command -v say >/dev/null || { echo "make-audio-fixtures: needs macOS 'say'" >&2; exit 1; }
command -v afconvert >/dev/null || { echo "make-audio-fixtures: needs macOS 'afconvert'" >&2; exit 1; }

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for script in "$SRC"/*.script; do
    name="$(basename "$script" .script)"
    SCRIPT="$script" NAME="$name" WORK="$WORK" OUT="$OUT" \
    THERAPIST_VOICE="$THERAPIST_VOICE" CLIENT_VOICE="$CLIENT_VOICE" RATE="$RATE" \
    python3 -I - <<'PY'
import os, subprocess, wave

script, name, work, out = (os.environ[k] for k in ("SCRIPT", "NAME", "WORK", "OUT"))
rate = int(os.environ["RATE"])
voices = {"T": os.environ["THERAPIST_VOICE"], "C": os.environ["CLIENT_VOICE"]}
sources = {"T": "You", "C": "Call audio"}
GAP = 0.6  # seconds between turns

def speak(voice, text, path):
    subprocess.run(
        ["say", "-v", voice, "-r", "170", "-o", path,
         "--file-format=WAVE", "--data-format=LEI16@%d" % rate, text],
        check=True)
    with wave.open(path, "rb") as w:
        assert w.getframerate() == rate and w.getnchannels() == 1 and w.getsampwidth() == 2
        return w.readframes(w.getnframes())

silence = lambda seconds: b"\x00\x00" * int(round(seconds * rate))
tracks = {"T": bytearray(), "C": bytearray()}
lines = []
clock = 0  # frames
for raw in open(script, encoding="utf-8"):
    raw = raw.strip()
    if not raw or raw.startswith("#"):
        continue
    if raw.startswith("pause "):
        gap = silence(float(raw.split()[1]))
        for t in tracks.values():
            t.extend(gap)
        clock += len(gap) // 2
        continue
    who, text = raw.split(":", 1)
    text = text.strip()
    pcm = speak(voices[who], text, os.path.join(work, "turn.wav"))
    frames = len(pcm) // 2
    other = "C" if who == "T" else "T"
    tracks[who].extend(pcm)
    tracks[other].extend(silence(frames / rate))
    lines.append("[%02d:%02d] %s: %s" % (clock // rate // 60, clock // rate % 60, sources[who], text))
    gap = silence(GAP)
    for t in tracks.values():
        t.extend(gap)
    clock += frames + len(gap) // 2

for key, label in (("T", "mic"), ("C", "call")):
    wav_path = os.path.join(work, "%s.%s.wav" % (name, label))
    with wave.open(wav_path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
        w.writeframes(bytes(tracks[key]))
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", "LEF32@%d" % rate, "-c", "1",
         wav_path, os.path.join(out, "%s.%s.caf" % (name, label))], check=True)

with open(os.path.join(out, name + ".expected.txt"), "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print("%s: %.1fs, %d lines" % (name, clock / rate, len(lines)))
PY
done
