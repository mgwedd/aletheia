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
- `Assistant` — the local LLM used for summaries and chat. There are
  multiple implementations behind this one protocol, chosen per Mac (see
  **AI backend** below): `FoundationModelsAssistant` (Apple Intelligence,
  on-device) and `OllamaClient` (a local Ollama server over
  `127.0.0.1:11434`). `AssistantService` builds the prompts and is what the
  summary/chat views call.
- `Integrations` is the one registry that decides which concrete type backs
  each adapter; views ask it for a `Transcribing` or `AssistantService` and
  never construct a client directly. Its `effectiveAssistantBackend` resolves
  the user's preference against what the machine actually supports, and
  `makeAssistant()` hands back the matching implementation.

### AI backend (tiered, on-device first)

Summaries and chat run against a local model, picked to keep setup as close
to zero-install as the hardware allows:

1. **Apple Intelligence (primary).** On a Mac that supports it,
   `FoundationModelsAssistant` uses Apple's on-device Foundation Models —
   no install, no model download, no external process, and the OS keeps the
   model updated. The whole file sits behind `#if canImport(FoundationModels)`
   so it compiles out on toolchains whose SDK predates the framework (the CI
   image today) and lights up automatically when built with a newer Xcode.
2. **Ollama (fallback).** Where Apple Intelligence isn't available,
   `OllamaClient` talks to a local Ollama server. This is the one backend
   that needs a one-time install, and the setup/status screens only ask for
   it when it's the backend actually in use.
3. **Embedded llama.cpp (staged).** The planned third tier bundles the
   official [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp)
   runtime (pinned) inside the app, updated as part of the normal app-update
   process, with GGUF models downloaded/refreshed separately (like the
   Whisper models). The `AssistantBackend.localLlama` case and the resolver
   already accommodate it; wiring the runtime is deferred because the heavy
   C++ build needs a real Mac to verify. Only official/first-party runtimes
   are used — no third-party LLM wrappers, per the supply-chain constraint.

`AssistantBackendResolver` is the pure decision function (given what's
available, which backend wins); it's unit-tested in isolation and carries no
framework dependency. The user can override the automatic choice in Settings.

Key files:

- `Services/Store.swift` — all patient/session file I/O.
  `gatherPatientContext(for:)` is the one place cross-transcript context
  gets assembled for the "ask across all sessions" feature. It's
  deliberately naive (concatenate every transcript, newest first, with
  dated headers) — if transcript volume ever outgrows the model's context
  window, that's the only function that needs to change (e.g. to
  embedding-based retrieval). Its `gatherCitedPatientContext` variant tags
  each session (`[S1]` newest-first) in the context so the model can cite its
  sources; `Services/Citations.swift` then maps those tags back to real dates,
  rewrites the answer, and appends a plain-language "Sources" line the
  therapist can trust.
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
- `Services/Spotlight/` — optional macOS Spotlight indexing. Off by default
  and **metadata-only** (patient names and session dates, never transcript or
  summary content), because names in system-wide search are a privacy
  trade-off the user opts into (Settings › Spotlight Search). The index-and-
  route logic (`SpotlightItemBuilder`) is pure and unit-tested; the
  CoreSpotlight calls (`SpotlightIndexer`, `SpotlightContinuationModifier`)
  are a thin, SDK-guarded layer. Tapping a hit opens the patient.
- `Services/Reminders/` — follow-up reminders into the user's Reminders app
  (EventKit), only on an explicit "Remind Me" action from a session. The
  content/timing logic (`SessionReminderBuilder`) is pure and unit-tested; the
  EventKit call (`ReminderScheduler`) is a thin, SDK-guarded layer behind the
  `ReminderScheduling` adapter.

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

`Tests/SessionNotesTests/IntegrationTests.swift` exercises the storage,
search, retrieval, and export layers together against a real temp-directory
store — headless "integration" coverage that runs reliably in CI (UI
automation would be flakier and is deferred).

`.github/workflows/smoke-test.yml` runs this same build + test on real macOS
runners for every push and pull request — it's the first place the app is
actually compiled, so it doubles as the build smoke test. Notable practices,
all using only first-party GitHub actions plus Homebrew CLIs (no third-party
marketplace actions, per the supply-chain constraint):

- **Two-toolchain matrix.** `macos-15` (Xcode 16) is the required signal;
  `macos-26` (Xcode 26) runs as a non-blocking canary — it's the only place
  the `#if canImport(FoundationModels)` Apple Intelligence path actually
  compiles, so a newest-SDK regression surfaces without blocking the merge.
- **Readable, annotated logs.** `xcodebuild` is piped through `xcbeautify`
  with `--renderer github-actions`, so warnings/errors show up as inline
  annotations; `set -o pipefail` + `NSUnbufferedIO=YES` preserve exit codes
  and stream output live.
- **Non-interactive & bounded.** `-skipPackagePluginValidation` avoids a
  package-plugin trust prompt hanging the run, and a job `timeout-minutes`
  caps stuck builds.
- **Caching & diagnostics.** The resolved Swift packages
  (SwiftWhisper/whisper.cpp) are cached per runner image; a per-target
  code-coverage summary is written to the job summary; and on failure the
  `.xcresult` bundle is uploaded as an artifact so a maintainer can open it
  in Xcode instead of re-running CI.

## Releasing

Push a tag like `v1.1.0` and `.github/workflows/release.yml` builds the
ad-hoc-signed app, packages a drag-to-Applications **DMG** with `hdiutil`,
generates the **`appcast.json`** the in-app updater polls, and publishes both
as a GitHub Release with the `gh` CLI (no third-party release actions). The
updater's default feed is that release's `appcast.json` asset, so cutting a
tag is all it takes to offer an update to installed copies. Releases are
ad-hoc signed (no notarization), so first launch still needs a right-click →
Open.

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
