# Privacy Policy

_Last updated: 2026-09-17_

**Plain-language summary:** Aletheia runs entirely on your Mac. The developer
does **not** collect, receive, transmit, store, or have any access to your data
or your patients' data. There are no accounts, no analytics, no telemetry, and
no developer-operated servers that receive your data.

> This document is a template provided for transparency. It is **not legal
> advice**. Because Aletheia is used with protected health information (PHI),
> have your own counsel review this and your practice's privacy notices before
> relying on them.

## 1. Who this covers

This policy describes the Aletheia macOS application ("the App"). It does not
govern software you separately install (e.g., Ollama) or model files you choose
to download — those are covered by their own providers' terms and policies.

## 2. What the developer collects

**Nothing.** The App has no analytics, no crash reporting, no usage tracking,
no accounts, and no developer backend. The developer cannot see who uses the
App or what it is used for.

## 3. Your data stays on your device

Recordings, transcripts, summaries, notes, comments, medications, clinical
history, and patient information are stored **only** in the data folder you
choose on your Mac. They are never uploaded to the developer or any third party
by the App. You control that folder, its backups, and who can access your Mac.

## 4. Network connections the App makes

The App works offline for its core features. It makes only these outbound
connections, and **none of them carry patient data**:

- **Update check** — the App fetches a small version file (an "appcast") to see
  whether a newer release exists. This is an ordinary web request (your IP
  address and the App version are visible to the host); no patient data is sent.
- **Model downloads (only when you ask)** — when you choose to download a
  speech-to-text or language model, the App downloads that model file from its
  host (for example a model registry or `ollama.com`). Files are downloaded to
  you; no patient data is uploaded.
- **Local AI** — Ollama runs on your machine and is reached only at
  `127.0.0.1` (your computer). Traffic does not leave the Mac.

## 5. You are the data controller

You (the clinician or practice) are the controller/custodian and, where
applicable, the HIPAA **covered entity** for the patient data you create with
the App. Because the developer never receives PHI, the developer is **not your
business associate** for the App, and no Business Associate Agreement (BAA) is
required for the App itself. You remain responsible for lawful collection,
patient consent, retention, and disclosure of that data.

## 6. Security

Protecting the data on your Mac is your responsibility. Enable **FileVault**,
use the App's **Touch ID / password lock**, keep backups, and restrict physical
and account access to the computer. See [SECURITY.md](SECURITY.md).

## 7. Children

The App is a professional tool and is not directed to children.

## 8. Changes

Updates to this policy will be posted here with a new "Last updated" date.

## 9. Contact

Questions about this policy: open an issue on the project's repository.
