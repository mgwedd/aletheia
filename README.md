# aletheia — Session Notes

A local-only macOS app for a therapist to record, transcribe, and summarize
browser-based video therapy sessions, and to ask questions across a
patient's session history. Privacy is the whole point: session audio is
PHI, so nothing here ever leaves the Mac it runs on.

See **[docs/SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** for the end-user setup
walkthrough and **[CONSENT.md](CONSENT.md)** for the consent/legal note
that applies before recording any real session.

## Why a native Swift/SwiftUI app

An earlier draft of this app was a Python/Tkinter script hand-wrapped into
a `.app` bundle that shelled out to `ffmpeg`, `whisper-cli`, and `ollama`
as subprocesses. That works, but it isn't how you'd build this for real:
no code signing/notarization story, no sandboxing, no proper permission
prompts, and a dependency on the system `python3` that Apple has been
deprecating. This is a ground-up rewrite as a native macOS app, chosen
deliberately over that approach and over Electron, to get:

- **A real, sandboxed macOS app.** `App Sandbox` + Hardened Runtime are
  both on (see `SessionNotes/Sources/SessionNotesApp/Resources/SessionNotes.entitlements`).
  This is possible specifically because nothing in this app spawns an
  external process — see below.
- **No external CLI dependencies.** Transcription runs in-process via
  [SwiftWhisper](https://github.com/exPHAT/SwiftWhisper) (a Swift binding
  for whisper.cpp), and Ollama is reached over its local HTTP API rather
  than the `ollama` CLI. The only thing installed outside the app itself
  is Ollama's own Mac app.
- **No BlackHole / virtual audio driver.** The original design captured
  the call's audio by routing it through a third-party kernel-adjacent
  audio driver (BlackHole) that had to be installed and wired up in Audio
  MIDI Setup. This version captures system audio with **ScreenCaptureKit**
  in audio-only mode instead — a built-in macOS API gated by a single
  system permission (the same one screen recorders use), no driver
  install, no manual routing.
- **Proper permission handling.** Microphone and Screen & System Audio
  Recording are both requested through normal macOS APIs and show up as
  normal System Settings toggles, with plain-language guidance in-app and
  in Settings > Status when either is off.

Distribution is ad-hoc signed (no Apple Developer account/notarization),
so the first launch needs a right-click > Open — see the setup guide.

## Architecture

```
<dataRoot>/Patients/<Patient-Slug>/
  patient.json
  patient_chat.json
  YYYY-MM-DD_Session/
    mic.caf          # therapist's microphone (AVAudioEngine tap)
    call.caf          # the other side of the call (ScreenCaptureKit audio)
    transcript.txt    # merged, timestamped, speaker-labeled
    summary.txt
    chat.json
```

`<dataRoot>` defaults to a folder the user picks inside iCloud Drive (so
backup is automatic) via `NSOpenPanel`; sandboxed access to it persists
across launches via a security-scoped bookmark
(`Services/SecurityScopedBookmark.swift`). Data is otherwise
plain, Finder-browsable JSON/text — never a database — matching the design
goal of a non-technical user being able to see and understand her own
files.

### Integrations (adapter layer)

The external integrations are behind protocols in `Services/Integrations/`,
so each is swappable without touching the UI:

- `Transcribing` — speech-to-text (implemented by `WhisperTranscriber`,
  i.e. whisper.cpp compiled into the app via SwiftWhisper; no external CLI
  or GUI app).
- `Assistant` — the local LLM used for summaries and chat (implemented by
  `OllamaClient` over `127.0.0.1:11434`). `AssistantService` builds the
  prompts and is what the summary/chat views call.
- `Integrations` is the one registry that decides which concrete type backs
  each adapter; views ask it for a `Transcribing` or `AssistantService` and
  never construct a client directly. Swapping a backend is a one-line change
  there.

Key files:

- `Services/Store.swift` — all patient/session file I/O.
  `gatherPatientContext(for:)` is the one place cross-transcript context
  gets assembled for the "ask across all sessions" feature. It's
  deliberately naive (concatenate every transcript, newest first, with
  dated headers) — if transcript volume ever outgrows the model's context
  window, that's the only function that needs to change (e.g. to
  embedding-based retrieval).
- `Services/MicRecorder.swift` / `Services/SystemAudioCapture.swift` /
  `Services/SessionRecorder.swift` — mic and call audio are recorded as
  two separate files rather than mixed down to one; that's what lets the
  transcript label lines "Therapist" vs. "Call audio" instead of a single
  blended track.
- `Services/WhisperTranscriber.swift` / `Services/AudioResampler.swift` /
  `Services/WhisperModelDownloader.swift` — in-process transcription via
  SwiftWhisper, with a model downloader (no Terminal/Homebrew step) that
  streams progress into Settings.
- `Services/OllamaClient.swift` — talks to `http://127.0.0.1:11434`
  directly; also drives an in-app model-download progress bar via
  Ollama's `/api/pull` streaming endpoint.
- `Services/ToolHealth.swift` — the plain-language status checks shown in
  Settings (permissions granted? model downloaded? Ollama reachable?).

## Building

Requires a Mac with Xcode 16+ installed. (The code was authored on Linux
with no local macOS/Xcode; it's compiled and unit-tested on every push by
the macOS CI in `.github/workflows/smoke-test.yml` — see **Known
limitations** for what CI does and doesn't cover.)

```bash
./scripts/build.sh
```

This installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) via
Homebrew if needed, generates `SessionNotes.xcodeproj` from
`SessionNotes/project.yml`, and produces an ad-hoc signed, Hardened
Runtime build at `dist/Session Notes.app`. `project.yml` (rather than a
checked-in `.xcodeproj`) is the source of truth for the project, which
keeps it diffable and avoids hand-edited `.pbxproj` merge conflicts.

## Testing

`Tests/SessionNotesTests` covers the platform-independent logic — patient
slug/collision handling, session date-folder naming and collisions,
transcript/summary persistence, cross-session context ordering, and the
deterministic session-ID scheme (`Services/StableID.swift`) — via
`@testable import SessionNotes` against a temp directory `Store`, plus the
prompt templates in `Services/Prompts.swift`. Run them from Xcode
(`Cmd+U`) or:

```bash
cd SessionNotes && xcodegen generate && xcodebuild test -scheme SessionNotes -destination 'platform=macOS'
```

Audio capture, transcription, and Ollama networking aren't covered by
these tests — they need real hardware/permissions/services and are best
verified by hand per the setup guide's walkthrough.

`.github/workflows/smoke-test.yml` runs this same build + test on a macOS
runner for every push and pull request — it's the first place the app is
actually compiled, so it doubles as the build smoke test.

## Known limitations

- **Runtime paths need manual verification.** CI compiles the whole app
  (including SwiftWhisper/whisper.cpp) on macOS and runs the unit tests, so
  it builds and the platform-independent logic is covered. What CI can't
  exercise is the hardware/permission/service-dependent flow: microphone
  and Screen & System Audio Recording capture, on-device Whisper
  transcription, and the Ollama round-trips. Those still need a hands-on
  pass on a real Mac (the PR's test-plan checklist walks through them)
  before trusting the app with a real session.
- **Mic/call sync isn't sample-accurate.** The two audio tracks start a
  few milliseconds apart (whichever of AVAudioEngine/ScreenCaptureKit
  spins up first); fine for matching up who-said-what at conversation
  granularity, not frame-accurate lip sync.
- **CPU-only inference.** SwiftWhisper/whisper.cpp uses Metal where
  available but there's no bundled CoreML encoder, so larger Whisper
  models will be noticeably slower on an Air than on a machine with more
  cores. The default ("Small") model is chosen for that reason.
