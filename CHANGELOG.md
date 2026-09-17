# Changelog

All notable changes to Session Notes are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/); the project adopts
[semantic versioning](https://semver.org/) once the first release is tagged.
Cutting a `v*` tag builds the release and the in-app updater's `appcast.json`.

## [Unreleased]

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

### Infrastructure
- App Sandbox + Hardened Runtime; no external process is ever spawned.
- GitHub Actions pipeline (first-party/Apple/Homebrew tooling only): CI matrix
  (`macos-15` required, `macos-26` canary), continuous-delivery DMG artifacts,
  and a tag-driven release that generates the updater feed and supports
  secret-gated Developer ID signing + notarization.

### Not yet shipped
- Embedded llama.cpp needs a one-time Mac bring-up (see the README).
- Google-Docs-style inline comment highlighting and streaming ("live typing")
  chat responses are in progress.
