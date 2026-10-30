# Aletheia

**Session notes for therapists, written on your Mac and kept on your Mac.**

Aletheia records a video-call therapy session, transcribes it, drafts a progress note, and answers questions across a patient's history. Speech recognition and the AI both run on your computer. Patient data never goes to a server.

![A session in Aletheia: the transcript beside the drafted progress note](docs/images/session.png)

> **License:** source-available, not open source. All rights reserved; see [LICENSE](LICENSE), [Terms](TERMS.md) and [Privacy](PRIVACY.md).

## TL;DR

- **What:** a macOS 14+ app that turns a recorded session into a transcript, a progress note (narrative, SOAP, DAP, BIRP or GIRP) and a searchable history.
- **Private by design:** no patient content leaves the Mac. No analytics, no telemetry, no AI server. The app has no network access of its own; a sandboxed helper fetches only updates, models and a signed license revocation list.
- **Get it:** limited beta at [astrealabs.com/aletheia/beta](https://astrealabs.com/aletheia/beta).

| Topic | Read |
|---|---|
| Using it | [Setup guide](docs/SETUP-GUIDE.md) · [Recording consent](CONSENT.md) · [Data safety and backups](docs/DATA-SAFETY.md) |
| Policies | [Privacy](PRIVACY.md) · [Terms](TERMS.md) · [License](LICENSE) · [Third-party notices](THIRD-PARTY-NOTICES.md) |
| Security | [Security policy](SECURITY.md) · [Threat model](docs/THREAT-MODEL.md) · [Encryption](docs/ENCRYPTION.md) · [Safeguards](docs/HIPAA-SAFEGUARDS.md) |
| How it works | [Architecture and developer reference](docs/ARCHITECTURE.md) · [Design decisions](docs/DESIGN-DECISIONS.md) · [Fine-tuning pipeline](docs/FINETUNING-PIPELINE.md) |
| Requirements | [Acceptance criteria](docs/spec/ACCEPTANCE-CRITERIA.md) · [Behaviour reference](docs/spec/BEHAVIOR-REFERENCE.md) · [Test execution layer](docs/spec/EXECUTION-LAYER.md) |
| History | [Changelog](CHANGELOG.md) |

## A tour

### Your caseload in one place

Every patient and session, with one search across transcripts, your notes and progress notes.

![The patient list and a patient's sessions](docs/images/patients.png)

### Record, transcribe, draft

Click **Record Session** when the video call starts and **Stop** when it ends. Aletheia transcribes both sides of the call, then drafts a progress note in your format from the transcript and your own notes. Edit it, then copy it into your record or export it as PDF, Word or Markdown.

![A transcript with the drafted progress note](docs/images/note.png)

### Ask about a session or a patient

Ask a question of one session or a patient's whole history. Answers say which sessions they read.

![Asking about a patient's history](docs/images/ask.png)

### What stays on your Mac

- Recording, transcription, notes and answers all happen locally. Raw audio is deleted once it is transcribed.
- The app runs in the macOS App Sandbox. Settings > Security shows what it can reach, read from its own signature.
- Apple Intelligence is turned off, so every AI path is provably on-device.
- The data folder stays out of Time Machine and iCloud device backups by default, and nothing backs it up for you: arrange your own, to an encrypted disk ([how](docs/DATA-SAFETY.md)).

Always read the transcript and note before relying on them: names and clinical terms are often misheard, and AI drafts can be wrong. Aletheia is a tool, not clinical advice. Read [CONSENT.md](CONSENT.md) before recording anyone.

## Getting started (therapists)

You need macOS 14 or newer. Apple silicon with 16 GB of memory gives good results; 8 GB uses a smaller model. The AI model takes about 2.5 GB on most Macs (16.5 GB on Apple silicon with 48 GB+ memory), plus space for transcription.

1. Apply for the beta; you receive a license key and a download link by email.
2. Open the `.dmg` and drag **Aletheia** into **Applications**.
3. Work down the first-run checklist: license, data folder (**Use the standard location** is the default), microphone, call audio, the two model downloads, and the terms.
4. **Add Patient**, **New session**, then **Record Session**.

After the downloads, Aletheia works offline. If a checklist row won't turn green, see the [Setup guide](docs/SETUP-GUIDE.md). For anything else, **Help → Aletheia Doctor…** builds a health report meant to carry no patient information.

## For code auditors

Aletheia is source-available so you can check its privacy claims yourself. Read the [threat model](docs/THREAT-MODEL.md) and [security policy](SECURITY.md) first.

### Run it

You need macOS 14+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` and is not checked in.

```bash
git clone https://github.com/mgwedd/aletheia.git && cd aletheia
./scripts/build.sh                                  # the shipped (production) build, ad-hoc signed → dist/Aletheia.app
xcodegen generate && open Aletheia.xcodeproj        # Debug builds run the dev tier, with every feature on
scripts/run-tests.sh Aletheia                       # unit tests; AletheiaAcceptance and AletheiaUITests are the other schemes
python3 scripts/make-demo-data.py                   # fictional patients with mock transcripts → ~/aletheia-demo-data
```

Choose the demo folder under Settings > Data folder to try the app without real patient data.

### Codebase at a glance

```
Sources/
  App/                 the app (SwiftUI). Has no network entitlement
    Models/            patients, sessions, chats
    Views/             screens; Theme/ holds colours and the text kit
    Services/          recording, transcription, AI, storage, search, app lock, audit log
      Crypto/          encryption, keystore, recovery key, backups
      Persistence/     SQLite, schema migrations
      Llama/           the built-in AI engine
    Resources/         entitlements, assets
  NetworkHelper/       sandboxed XPC service: the only code that reaches the internet
  WhisperEngine/       on-device speech recognition
Packages/              vendored llama.cpp and whisper.cpp
Tests/                 unit (AletheiaTests), acceptance (AletheiaAcceptance), UI (AletheiaUITests)
scripts/               build, release and the guard checks below
.github/workflows/     CI, release, secret scan, pin checks
```

### Where each claim is enforced

| Claim | Code | Checked by |
|---|---|---|
| The app itself cannot reach the network | `Sources/App/Resources/Aletheia.entitlements` | `scripts/check-entitlements.sh`, `EntitlementsPlistTests` |
| Only fixed assets are downloaded, by ID, never with patient data | `Sources/NetworkHelper` | `NetworkHelperSourceTests` |
| No analytics or crash-reporting SDKs | dependency manifests, `Sources/` | `scripts/check-no-telemetry-sdk.sh` |
| AI and transcription run on the Mac | `Services/Llama`, `Sources/WhisperEngine`, `Packages/` | `scripts/verify-model-pins.sh`, `scripts/check-runtime-pins.sh` |
| Patient names stay off notifications, menu bar, Spotlight | `PatientLabel` | `scripts/check-patient-label.sh` |
| Access to patient records is logged | `Services/AuditLog.swift` | `scripts/check-audit-wiring.sh` |
| No secrets or patient files in the repo | n/a | `scripts/scan-secrets.sh` |

The [architecture reference](docs/ARCHITECTURE.md) covers data flow, storage, build tiers and CI. Every feature ships an [acceptance criterion](docs/spec/ACCEPTANCE-CRITERIA.md), an acceptance test and a UI test.
