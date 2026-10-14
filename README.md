# Aletheia

**Session notes for therapists, written on your Mac and kept on your Mac.**

Aletheia records a video-call therapy session, transcribes it, drafts a progress note, and lets you search and ask questions across a patient's history. The speech recognition and the AI both run on your computer. Patient data is never sent to a server, and there is no analytics or telemetry.

[For therapists](#for-therapists) · [How it works](#how-it-works) · [For developers](#for-developers) · [Setup guide](docs/SETUP-GUIDE.md) · [Security](SECURITY.md) · [Changelog](CHANGELOG.md)

> **License:** source-available, not open source. All rights reserved; see [LICENSE](LICENSE), [Terms](TERMS.md) and [Privacy](PRIVACY.md).

---

### Privacy First

- No patient content leaves the Mac. Recording, transcription, notes and chat are all local.
- The app makes a few requests that carry no patient data: a check for new versions (a plain download of a small file from GitHub), and downloads of the speech and AI models you choose to install.
- The app runs in the macOS App Sandbox and spawns no subprocesses. Its only network entitlement is outbound client connections.
- Raw audio is deleted after transcription unless you opt in to keeping it and encryption is on.
- Apple Intelligence is deliberately disabled so every AI path is provably on-device.
- The app has no backup feature of its own. Time Machine includes the data folder by default. See [docs/DATA-SAFETY.md](docs/DATA-SAFETY.md).

Aletheia is a tool, not legal or clinical advice. Read [CONSENT.md](CONSENT.md) before recording anyone.

---

## For therapists

You need a Mac running **macOS 14 or newer**, and 4 to 8 GB of free disk space for the downloads. Apple Silicon with 16 GB of memory gives the best results; 8 GB works with smaller models, which the app picks for you.

### 1. Install Aletheia

Download the latest `Aletheia-<version>.dmg` from the [Releases page](https://github.com/mgwedd/aletheia/releases), open it, and drag **Aletheia** into **Applications**.

The app is not notarized by Apple, so macOS will hesitate. **Right-click Aletheia, choose Open,** then confirm. You only do this once.

### 2. Set up with the checklist

On first launch Aletheia shows a checklist. Work down it:

1. **Data folder:** click **Choose Folder…** and pick where everything is stored (iCloud Drive or any folder you back up).
2. **Microphone:** click **Allow Microphone**.
3. **Call audio capture:** click **Allow**. macOS calls this "Screen Recording", but Aletheia only uses it to hear your video call. It does not capture the screen.
4. **Transcription model:** click **Download**.
5. **AI (Ollama):** the AI runs in a free app called [Ollama](https://ollama.com). You install it once, then Aletheia downloads the model for you. You never need Terminal.
   1. Click **Get Ollama**. Your browser opens ollama.com/download.
   2. Download Ollama, drag it into **Applications**, and open it once.
   3. Back in Aletheia, click **Launch Ollama** if the row still asks for it.
   4. Click **Download Model**. Aletheia fetches the model that fits your Mac (a few GB, once). Wait for the row to turn green.
6. **Terms & Privacy:** read and accept.

After the downloads, Aletheia works offline. If a row will not turn green, see the [Setup guide](docs/SETUP-GUIDE.md).

### 3. Your first session

1. Click **Add Patient** (the + button) and enter a name.
2. Click **New session**.
3. Open your video call as usual, then click **Record Session** (or use the menu bar icon).
4. Click **Stop** when finished. Transcription starts by itself if **Settings → General → Transcribe automatically when a recording ends** is on; otherwise click **Transcribe**.
5. Open the **Notes** tab to jot your own notes and generate the progress note. Choose the format (narrative, SOAP, DAP, BIRP or GIRP) under **Settings → Note format**. Use the **Length** menu to make it shorter or longer, then **Regenerate** to apply. **Edit** it, then **Copy** to paste into your record.
6. Use the **Ask** tab to question this session, or **Ask about all sessions** on the patient page. Answers say what was read.
7. The magnifying glass in the toolbar searches names, transcripts, notes and comments.

Always read the transcript and note before relying on them. Names and clinical terms are often misheard, and AI drafts can be wrong.

If something looks wrong, open **Help → Aletheia Doctor…** for a health report that contains no patient information.

---

## How it works

### System overview

```mermaid
flowchart LR
  subgraph Mac["Your Mac (sandboxed app)"]
    UI["SwiftUI app<br/>window · menu bar · Doctor"]
    REC["Recorder<br/>AVAudioEngine + ScreenCaptureKit"]
    STT["Transcription<br/>Whisper (in-process)"]
    AI["Assistant<br/>notes · chat · digests"]
    DB[("Local data folder<br/>SQLite + files")]
    LLM["Ollama<br/>127.0.0.1:11434"]
    UI --> REC --> STT --> DB
    UI --> AI --> LLM
    AI <--> DB
    UI <--> DB
  end
  NET(["Internet"])
  Mac -. "update check · model downloads<br/>(no patient data)" .-> NET
```

### What a note or answer reads

- **Context window.** Ollama is sent a fixed context window (`num_ctx`) equal to this Mac's context budget, so it never truncates silently. Each Mac has a prompt budget: 16K tokens on 8 GB, 32K on 16 GB, 64K on 32 GB or more (one tier lower on Intel). A prompt over budget fails with a clear message and nothing is sent.
- **Tripwire.** If Ollama reports reading well under what was sent, the answer shows a notice that the model may not have read everything.
- **Progress.** Notes and chat show the stage, elapsed time and token counts while the model works.
- **Chat memory.** Past about 12,000 characters, older messages are replaced by a summary (also `/compact [focus]`). Source material is always sent fresh.
- **One session** chat sends the session's transcript.
- **Patient-wide chat** is sized from the Mac's budget less the instructions, conversation and question. Background, notes and comments (newest sessions first, up to a third of the room) come first; transcripts take the rest. If the transcripts fit, they go in whole, newest first. Otherwise it searches them for the question's names and words and sends the best passages with surrounding lines. If too little room is left, the question is refused rather than cut.

The search (`SessionSearch`) runs in memory, with indexes cached by content fingerprint and never written to disk:

- BM25 ranking over passages (a transcript line or a paragraph of notes);
- whole-word matching with a stemmer, one-letter typo tolerance, and sound-alike matching for names, because Whisper misspells them;
- quoted phrases match exactly; date phrases such as "past 6 months" narrow the sessions searched;
- exact counts ("14 mentions in 6 of 22 sessions"), and the model may say a topic was not discussed only when the search found nothing, worded "no match found".

Each all-session answer carries a coverage label built from what was actually sent, for example `Read: notes and comments from 22 sessions · transcript passages from 6 of 22 sessions (search: 14 mentions)`. Sessions whose notes were cut short or left out, and unreadable sessions, are reported as such. There is no click-through from a search hit to a transcript moment.

### Session digests

A digest is an AI-written summary of one session, stored as `digest.json` beside its notes and never shown as the record. It is built in the background, at low priority behind notes and chat, after a transcription finishes or a transcript edit is saved.

- The transcript is split into sections of about ten minutes (cut sooner at 12,000 characters). Each section gets a digest of topics, the patient's key statements, interventions, affect, risk flags and follow-ups, tied to its time range. The sections are then merged into one session digest of at most about 2,000 characters.
- A digest is valid only for the transcript fingerprint, model and prompt version it was built from; otherwise it is ignored and rebuilt at the next trigger.
- Progress shows as one line on the session ("Building digest · section 4 of 11"). A failed or cancelled build is retried at the next trigger.
- Digests are sealed like transcripts when encryption is on. Notes and chat read transcripts, not digests.

### Where data lives

```
<data folder>/
  .aletheia.json                  schema version stamp
  Aletheia.sqlite                 notes, comments and chat threads
  audit.log                       PHI-free event log
  .aletheia-keystore.json         only when encryption is on
  .backups/{migrations,snapshots,archives}/
  Patients/<Patient-Slug>/
    patient.json
    YYYY-MM-DD_Session/
      session.json  mic.caf  call.caf  transcript.txt  summary.txt
      note.<format>.txt  digest.json
```

`mic.caf` and `call.caf` are deleted after transcription by default. Schema changes are append-only migrations, with a pre-migration copy of the database in `.backups/migrations`. The SQLite file is a single `records` table of `(kind, id, owner, item, payload)`.

The encrypted archive service covers only the SQLite database and is not invoked from the app. Transcripts, notes and digests are backed up only through the data folder itself (for example Time Machine). The app has no delete-session action.

### Transcription

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) v1.9.5 runs in-process on the GPU via Metal.
- Silero VAD v6.2.0 skips silence so long pauses cannot trigger repeated phantom lines.
- Microphone ("You") and call audio ("Call audio") are captured as separate tracks and merged by timestamp.

The only third-party dependency is the official whisper.cpp XCFramework (ggml-org, pinned by checksum). The Silero model is MIT-licensed, under 1 MB, pinned by SHA-256. A sandboxed native app can capture call audio with ScreenCaptureKit and run Whisper in-process, which keeps the privacy boundary small enough to audit.

### AI backends and recommended models

- **Ollama** is the runtime in use. The app talks to it on `127.0.0.1` only.
- **Apple Intelligence** is disabled via `Integrations.appleIntelligenceBlocked = true`.
- **Embedded llama.cpp** is linked into every build and offered as the "Built-in model" backend in developer builds. Ollama is the default backend. See [Embedded llama.cpp](#embedded-llamacpp).

`ModelAdvisor` picks defaults from your hardware:

| Mac | Speech model | AI model |
|---|---|---|
| Apple Silicon, 16 GB+ | medium.en | llama3.1:8b |
| Apple Silicon, 8 GB+ | small.en | llama3.2:3b |
| Intel, 16 GB+ | small.en | llama3.1:8b |
| Other, 8 GB+ | base.en | llama3.2:3b |
| Under 8 GB | base.en | llama3.2:1b |

### Storage protection

- **Sandbox, lock, audit:** App Sandbox is on; the optional app lock uses LocalAuthentication; the audit log records events (unlock, encryption changes, export) without content; deletions are not recorded.
- **Encryption (dev tier only):** AES-256-GCM in 1 MiB chunks, with a random data key wrapped by a passphrase (PBKDF2-HMAC-SHA256, 600,000 iterations). See [docs/ENCRYPTION.md](docs/ENCRYPTION.md).
- **Backups:** rolling database snapshots and pre-migration copies are kept in `.backups`. Time Machine is the supported backup.

### Build tiers

Features are grouped into tiers chosen at compile time. Each includes the one before it; the released DMG is **production**.

```mermaid
flowchart LR
  P["production<br/>recording · transcription · notes · chat · source citations<br/>search · export · app lock · audit log · Doctor"]
  V["preview<br/>+ Spotlight<br/>medications · suggested questions"]
  D["dev<br/>+ built-in model · Reminders/Calendar<br/>extra encryption · App Intents"]
  P --> V --> D
```

Debug builds are `dev`; Release builds are `production`. Tiers are set by `ALETHEIA_PREVIEW` and `ALETHEIA_DEV` compilation conditions in `project.yml`.

---

## For developers

### Prerequisites

- A Mac with full **Xcode 16+**
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

There is no checked-in `.xcodeproj`. `project.yml` is the source of truth.

### Build and test

```bash
git clone https://github.com/mgwedd/aletheia.git && cd aletheia
./scripts/build.sh            # generates the project, Release build, ad-hoc signed → dist/Aletheia.app
xcodegen generate && open Aletheia.xcodeproj    # or work in Xcode
xcodebuild test -scheme Aletheia -destination 'platform=macOS'
```

To test a specific tier, pass `SWIFT_ACTIVE_COMPILATION_CONDITIONS` to `xcodebuild`: `"DEBUG"` (production), `"DEBUG ALETHEIA_PREVIEW"` or `"DEBUG ALETHEIA_PREVIEW ALETHEIA_DEV"`. The root `Package.swift` also supports `swift test`, always at the dev tier.

### Repository map

```
Sources/App/
  AletheiaApp.swift       entry point: main window, Doctor, Settings, menu bar
  Models/                 Patient, SessionRecord, ChatThread, …
  Views/                  SwiftUI views
  Services/               recorder, transcriber, assistant, store, app lock, settings
    Digest/               section splitting and background digest builder
    Search/               in-memory BM25 search
    Persistence/          SQLite core, schema migrator, migration backup
    Repositories/         annotation and chat repositories
    Crypto/               encryption, keystore, snapshots, backup
    Integrations/         assistant/transcriber factory, backend selection
    Features/             build tiers, feature registry, Doctor
    Llama/                embedded llama.cpp backend
Tests/AletheiaTests/      XCTest suite
scripts/                  build, release, secret scan, entitlement and pin checks
docs/                     setup, data safety, encryption, HIPAA safeguards
```

### Continuous integration

```mermaid
flowchart LR
  PR["Pull request"] --> S["Smoke test<br/>build + test × production/preview/dev<br/>entitlements guard · secret/PHI scan"]
  S --> M["Merge to main"]
  M --> S2["Smoke test on main"]
  S2 -- "passes" --> AR["Auto Release<br/>conventional commits → semver"]
  AR --> TAG["v* tag"] --> REL["release.yml<br/>DMG · appcast.json · GitHub Release"]
```

CI runs on macOS runners (the only place the Swift code compiles). Developer ID signing and notarization run only when signing secrets are configured; otherwise the DMG is ad-hoc signed. Model downloads are pinned by commit and SHA-256, checked weekly by `verify-model-pins`.

### Conventions

- **Conventional Commits** drive releases: `feat` → minor; `fix`, `perf`, `revert` → patch; `!` or `BREAKING CHANGE` → major; everything else → no release. Squash-merge with the PR title as the subject.
- **`CHANGELOG.md` is generated.** Do not edit it by hand.
- **Privacy invariants:** PHI never leaves the Mac; no analytics; the only outbound calls are the update check, opt-in model downloads, and loopback Ollama. Apple Intelligence stays disabled.
- **Dependencies:** first-party and pinned. GitHub Actions are first-party only.
- **Settings** follow the `AppSettings` pattern: UserDefaults-backed, `private enum Keys`, values loaded in `init`.
- **Colors** come from `Theme` (`Sources/App/Views/Theme`); no color literals in screens.
- Enable the pre-commit hook: `git config core.hooksPath scripts/hooks`. It runs `scripts/scan-secrets.sh`, a fail-closed check for secrets and PHI-like filenames.

### Embedded llama.cpp

The embedded llama.cpp engine (`LlamaEngine`) is linked into every build on Apple Silicon. It is offered as the "Built-in model" backend in developer builds only (production and preview use Ollama).

Downloadable models from ggml-org on Hugging Face, pinned to a revision and verified by SHA-256:

| Mac | Model |
|---|---|
| 16 GB+ | Llama 3.1 8B Instruct Q4_0 (~6.0 GB) |
| 8–15 GB | Gemma 2 9B Q4_0 (~5.2 GB) |
| Under 8 GB | Gemma 2 2B Q4_0 (~1.6 GB) |

The engine applies the model's chat template. Context window is sized to the prompt plus reply, rounded up to a power of two (8K minimum), and capped at the RAM-based context budget and the model's training context limit. A prompt over the cap fails with a clear error, never silently truncated. Flash attention and 8-bit KV cache are on. The model unloads on app lock, on backend or model change, and after 30 minutes idle.

### Releases

Merging to `main` is enough once Smoke Test passes on the merge commit: Auto Release then computes the version, updates the changelog, tags it, and dispatches `release.yml`. A failed or cancelled run releases nothing, and if `main` has moved on, the newer commit's run releases the whole range. A manual release can be dispatched from the Actions tab.

---

## Known limitations

- The Swift code compiles only on macOS CI; recording and transcription on real hardware need manual verification before each release.
- Mic and call tracks are not sample-accurate with each other, so interleaved lines can be off by a short interval.
- Patient-wide chat on a long history sends search passages, not every transcript.
- A session longer than the Mac's prompt budget cannot be summarized in one pass.
- No CoreML encoder is bundled; transcription uses CPU/Metal.
- Encryption is in the dev tier only, and release builds are notarized only when signing secrets are configured.
