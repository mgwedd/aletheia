# aletheia — Session Notes

A local-only macOS app for a therapist to record, transcribe, and summarize
browser-based video therapy sessions, then search, annotate, and ask questions
across a patient's history. **Privacy is the whole point:** session audio is
PHI, so nothing ever leaves the Mac it runs on.

📖 [Setup guide](docs/SETUP-GUIDE.md) · ⚖️ [Consent note](CONSENT.md) · 📝 [Changelog](CHANGELOG.md)

## What it does

- 🎙 **Record** the therapist's mic and the call's audio as two tracks — no
  virtual audio driver.
- ✍️ **Transcribe** on-device (Whisper), speaker-labeled, then **summarize**
  with a local LLM.
- 🔎 **Search** across every patient and session; **export** a session or a
  whole history to Markdown.
- 💬 **Ask across sessions** — chat grounded in the transcripts, with the
  session date cited as its source.
- 🗒 **Notes & comments** — freeform per-session notes and inline transcript
  comments the AI chat takes into account.
- 🔔 **Fits the Mac** — Spotlight, Siri/Shortcuts, Reminders, Calendar,
  notifications, and an in-app updater.

## How a session flows

```mermaid
flowchart LR
  Mic[🎙 Microphone] --> Rec[Session Recorder]
  Call[🔊 Call audio via ScreenCaptureKit] --> Rec
  Rec --> Files[mic.caf + call.caf]
  Files --> Whisper[On-device Whisper]
  Whisper --> Transcript[transcript.txt]
  Transcript --> Summary[AI summary]
  Transcript --> Chat[Ask / cross-session chat]
  Notes[Notes + comments] --> Chat
  Chat --> Cited[Answer with cited sessions]
```

## Why native Swift/SwiftUI

An earlier draft shelled out to `ffmpeg`/`whisper-cli`/`ollama` from a
Python/Tkinter wrapper. This is a ground-up native rewrite so the app can be a
**real sandboxed macOS app** — App Sandbox + Hardened Runtime on — which is
possible only because it never spawns an external process:

- **Transcription in-process** via [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper)
  (whisper.cpp), not a CLI.
- **Call audio via ScreenCaptureKit** in audio-only mode — one system
  permission, no BlackHole/virtual driver.
- **Local LLM** reached in-process or over `127.0.0.1`, never by spawning a
  binary.

Distribution is ad-hoc signed by default (no Apple Developer account), so the
first launch needs a right-click → Open — see the setup guide. Tagged releases
can be Developer ID-signed and notarized (below).

## Architecture

```mermaid
flowchart TD
  UI[SwiftUI views] --> Integ[Integrations registry]
  UI --> Store[Store — Finder-browsable files]
  UI --> DB[CommentStore — SQLite]
  Integ --> Transcribing
  Integ --> AssistantService
  Transcribing --> Whisper[WhisperTranscriber]
  AssistantService --> Backend{Assistant backend}
  Backend --> AI[Apple Intelligence]
  Backend --> Llama[Built-in llama.cpp]
  Backend --> Ollama[Ollama]
```

Every external integration sits behind a protocol in `Services/Integrations/`,
so a backend swaps without touching the UI. The one registry (`Integrations`)
decides which concrete type backs each adapter.

**Storage is deliberately plain and Finder-browsable** — one folder the user
picks (defaults inside iCloud Drive, so backup is automatic), reached across
launches via a security-scoped bookmark:

```
<dataRoot>/
  SessionNotes.sqlite          # therapist's notes + inline comments (PHI, local)
  Patients/<Patient-Slug>/
    patient.json
    patient_chat.json
    YYYY-MM-DD_Session/
      mic.caf / call.caf        # two audio tracks
      transcript.txt            # merged, timestamped, speaker-labeled
      summary.txt
      chat.json
```

Everything except the annotations DB is plain JSON/text a non-technical user
can read. The one database is SQLite living *inside* that same folder, so it
backs up with everything else and never leaves the Mac.

## AI backend (tiered, on-device first)

The backend is chosen to keep setup as close to zero-install as the hardware
allows; the user can override it in Settings.

```mermaid
flowchart TD
  Start[Automatic] --> Q1{Apple Intelligence available?}
  Q1 -- yes --> AIB[Apple Intelligence — on-device, no install]
  Q1 -- no --> Q2{Built-in model ready?}
  Q2 -- yes --> LlamaB[Built-in llama.cpp]
  Q2 -- no --> OllamaB[Ollama — one-time install]
```

Only official/first-party runtimes are used (no third-party LLM wrappers).
Apple Intelligence and the llama.cpp binding compile in behind
`#if canImport(...)`, so they light up on a supporting Mac/toolchain and
compile out otherwise.

<details>
<summary>Bringing up the embedded llama.cpp backend (Mac, one-time)</summary>

The binding lives behind `#if canImport(llama)` and compiles out until the
package is linked, so CI stays green without building the heavy C++.

1. In `SessionNotes/project.yml`, uncomment the `llama` package stanza and the
   `- package: llama` dependency, and pin `revision:` to a **verified
   `ggml-org/llama.cpp` commit SHA** (don't track a branch).
2. `./scripts/build.sh` — `LlamaAssistant` now compiles and Settings shows a
   "Built-in Model" section to download a GGUF.
3. Verify `LlamaAssistant`'s `llama.h` calls against that pinned revision — the
   symbols weren't compiler-checked in CI.
4. Confirm the model download URLs and add a SHA-256 integrity check before
   shipping it enabled.
</details>

## Build · Test · Release

Requires a Mac with Xcode 16+. The project is generated from
`SessionNotes/project.yml` (XcodeGen) rather than a checked-in `.xcodeproj`.

```bash
./scripts/build.sh          # ad-hoc signed app in dist/
cd SessionNotes && xcodegen generate && xcodebuild test -scheme SessionNotes -destination 'platform=macOS'
```

CI/CD runs entirely on GitHub Actions with **only first-party actions plus
Apple/Homebrew CLIs** — no third-party marketplace actions:

```mermaid
flowchart LR
  PRs[push / PR] --> CI[CI — build + tests<br/>macos-15 required · macos-26 canary]
  Main[merge to main] --> CD[CD — DMG artifact per commit]
  Tag[tag v*] --> Rel[Release — DMG + appcast + GitHub Release]
  Rel --> Gate{signing secrets set?}
  Gate -- yes --> Note[Developer ID + notarize + staple]
  Gate -- no --> Adhoc[ad-hoc signed]
```

Unit/integration tests cover the platform-independent logic (storage, search,
retrieval/citations, prompt building, annotations) against a temp directory;
audio/transcription/LLM round-trips need a hands-on pass on a real Mac.
Signing & notarization are optional and secret-gated (see
`.github/workflows/release.yml` for the exact secret names).

## Known limitations

- **Runtime paths need manual verification.** CI compiles the app and runs the
  logic tests, but microphone/screen-audio capture, on-device Whisper, and LLM
  round-trips need a real Mac.
- **Mic/call sync isn't sample-accurate** — the two tracks start a few ms apart;
  fine for who-said-what, not frame-accurate lip sync.
- **CPU/Metal inference, no bundled CoreML encoder** — larger Whisper models are
  slower on an Air; the default (Small) is chosen for that.
