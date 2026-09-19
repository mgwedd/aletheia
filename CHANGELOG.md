# Changelog

All notable changes to Aletheia are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and [semantic
versioning](https://semver.org/).

**This file is generated at release time** from the [Conventional
Commit](https://www.conventionalcommits.org/) messages since the previous tag —
don't edit it in pull requests. Write a good commit subject (`feat: …`,
`fix: …`) and the release automation adds the entry for you.

## [1.21.0] - 2026-09-19

### Added
- add audio-retention privacy setting (transcript-only by default) (#84)

## [1.20.0] - 2026-09-19

### Added
- add idle auto-lock timeout (HIPAA automatic logoff)

## [1.19.0] - 2026-09-19

### Added
- show local AI engine status and active model

## [1.18.0] - 2026-09-19

### Added
- add SQLite-backed persistence core

## [1.17.0] - 2026-09-19

### Added
- add domain-neutral persistence-core seam

## [1.16.0] - 2026-09-19

### Added
- consistent DB snapshots for safe migrations and rollback

## [1.15.0] - 2026-09-19

### Added
- end-to-end-encrypted backup engine (local + staged iCloud)

## [1.14.0] - 2026-09-18

### Added
- note format in Settings (default free text) + Settings in app menu

## [1.13.0] - 2026-09-18

### Added
- inline transcript commenting — select a passage, comment in place

## [1.12.2] - 2026-09-18

### Fixed
- Aletheia menu name, always-visible New Patient, open Background

## [1.12.1] - 2026-09-18

### Fixed
- avoid await inside && autoclosure in ToolHealth
- live-updating status + reliable screen-recording detection

## [1.12.0] - 2026-09-18

### Added
- draft clinical progress notes in SOAP/DAP/BIRP formats

## [1.11.1] - 2026-09-18

### Fixed
- name the release DMG Aletheia-<ver>.dmg, not SessionNotes-

## [1.11.0] - 2026-09-18

### Added
- anchor transcript comments to a time in the session

## [1.10.0] - 2026-09-18

### Added
- multi-thread patient chat with a thread browser

### Fixed
- use a closure for onAppear so the defaulted reloadThreads type-checks

## [1.9.0] - 2026-09-18

### Added
- render assistant chat answers as native Markdown

## [1.8.0] - 2026-09-18

### Added
- optional Keychain unlock — remember the data key on this Mac
- enable/disable Tier-2 encryption from Settings with bulk migration and unlock gate
- encrypt session audio at rest with a streaming chunked cipher
- encrypt transcripts, summaries, chat, patient records and the notes DB at rest
- add FileProtector I/O choke point and EncryptionManager key lifecycle

## [1.7.0] - 2026-09-18

### Added
- add at-rest encryption crypto core (envelope cipher + passphrase keystore)
- tiered Ollama model picker in Settings (lighter / recommended / heavier)
- menu-bar Start/Pause/Stop for session recording

## [1.6.0] - 2026-09-17

### Added
- append-only local receipt for legal acceptance
- require & record local acceptance of Terms and Privacy Policy

## [1.5.0] - 2026-09-17

### Added
- disable Apple Intelligence backend (keep AI provably on-device)

## [1.4.0] - 2026-09-17

### Added
- edit the transcript in-app and warn on runaway recordings

## [1.3.0] - 2026-09-17

### Added
- Touch ID / password app lock and FileVault guidance (Tier 1)
- patient background — clinical history + medications, fed to AI context

### Fixed
- keep session header buttons from overflowing a narrow window

## [1.2.0] - 2026-09-17

### Changed
- The app is now named **Aletheia** everywhere it's shown — the window and menu,
  permission prompts ("Aletheia would like to…"), setup, and the distributed
  `Aletheia.app`/DMG. Internal identifiers (bundle id, Xcode target) are
  unchanged, so existing permission grants and data folders carry over.

## [1.1.0] - 2026-09-17

### Added
- Setup now asks for Calendar and Reminders access up front (optional), so the
  "Schedule Next Session" and "Remind Me" features are ready without an
  interrupting permission prompt mid-task. Declining just leaves those features
  off; you can enable them anytime. Access is checked without prompting.
- Hardware summary now shows the detected chip and CPU core count (e.g.
  "Apple M3 Pro · 12-core CPU · 36 GB memory") instead of a generic label.

## [1.0.0] - 2026-09-17

### Added
- Native macOS app: record a session's microphone and call audio (two tracks,
  via ScreenCaptureKit — no virtual audio driver), on-device Whisper
  transcription, and local-LLM summaries.
- Cross-session chat grounded in the transcripts, with the session date cited
  as its source; full-text search across patients/sessions; Markdown export of a
  session or a whole patient history.
- Therapist annotations: freeform per-session notes and inline transcript
  comments, stored in a local SQLite database inside the data folder and fed
  into the AI chat so it weighs the therapist's own judgment.
- Tiered on-device AI backend, chosen automatically and overridable in Settings:
  Apple Intelligence → built-in llama.cpp (staged) → Ollama. Hardware-aware
  model recommendations and in-app model downloads.
- Apple-platform integration: completion notifications, Siri/Shortcuts
  (App Intents), opt-in metadata-only Spotlight indexing, and "Remind Me" /
  "Schedule Next Session" via Reminders and Calendar.
- Guided first-run setup, permission/status checks, and an in-app updater that
  polls an appcast and installs new versions.

- Streaming chat responses with an adaptive, word-by-word reveal and a Stop
  control, across all backends (Ollama, Apple Intelligence, llama.cpp).
### Fixed
- Screen Recording setup no longer re-prompts on every health check and doesn't
  need an app relaunch: permission is checked with a non-prompting preflight, the
  system dialog appears once from an explicit Allow, and the checklist turns green
  live the moment access is granted.

### Infrastructure
- App Sandbox + Hardened Runtime; no external process is ever spawned.
- GitHub Actions pipeline (first-party/Apple/Homebrew tooling only): CI matrix
  (`macos-15` required, `macos-26` canary), continuous-delivery DMG artifacts,
  and a tag-driven release that generates the updater feed and supports
  secret-gated Developer ID signing + notarization.
- Automated releases from Conventional Commits: merges to `main` derive the
  semver bump, stamp the changelog and app version, tag, and publish — no manual
  version bumping. See the README's Releasing section.

### Not yet shipped
- Embedded llama.cpp needs a one-time Mac bring-up (see the README).
- Google-Docs-style inline comment highlighting is in progress.
