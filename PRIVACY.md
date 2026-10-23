# Privacy Policy

_Last updated: 2026-10-21_

**Plain-language summary:** Aletheia keeps clinical data in a folder you choose.
A cloud-synced folder may be copied by its provider. The app does not currently
upload an encrypted backup. The developer does not collect, receive, store, or
have access to your data or your patients' data. There are no accounts, analytics,
telemetry, or developer-operated servers that receive clinical data.

> This document is a template provided for transparency. It is **not legal
> advice**. Because Aletheia is used with protected health information (PHI),
> have your own counsel review this and your practice's privacy notices before
> relying on them.

## 1. Who this covers

This policy describes the Aletheia macOS application ("the App"). It does not
govern model files you choose to download; those are covered by their providers' terms and policies.

## 2. What the developer collects

The App has no analytics, crash reporting, usage tracking, accounts, or developer
backend. The developer cannot see who uses the App or what it is used for.
Update requests to GitHub may expose an IP address and app version to that host.

## 3. Where your data is stored

Recordings, transcripts, summaries, notes, comments, medications, clinical
history, and patient information are stored in the data folder you choose. The
folder picker opens in iCloud Drive when it is available and suggests it, but you
can pick any folder. A folder in iCloud Drive or another synced location is
copied by that provider. Choose a local folder if you want the data to remain on
this Mac. Production builds do not offer at-rest encryption for new data
folders, so use FileVault and encrypted backup media.

The App does not upload backups of its own. App
settings, downloaded models, and an optional remembered encryption key are
stored separately in the app container or login Keychain. Your data is not sent
to the developer or a developer-operated server.

## 4. Network connections the App makes

The App works offline for its core features. Its network paths are:

- **Update check** — when enabled (the default), the App fetches a version file (an "appcast")
  from GitHub. Your IP address and App version may be visible to the host; no
  patient data is sent.
- **Model downloads** — when you ask to download a speech-to-text or language
  model, the App downloads the file from Hugging Face. No patient data is
  uploaded by these requests.
- **Local AI** — the built-in AI runs inside the App on this Mac and makes no
  network requests.

A cloud-synced data folder may also be transferred by the provider's sync
software, outside the App's own network requests.

## 5. You are the data controller

You (the clinician or practice) are the controller/custodian and, where
applicable, the HIPAA **covered entity** for the patient data you create with
the App. Because the developer does not receive PHI through the App, the
developer is not your business associate for the App itself. You remain
responsible for lawful collection, patient consent, retention, and disclosure.

## 6. Security

Protecting the data on your Mac is your responsibility. Enable **FileVault**,
use the App's **Touch ID / password lock**, keep encrypted backups, and restrict
physical and account access to the computer. If the selected folder is
cloud-synced, protect that account. See [SECURITY.md](SECURITY.md).

## 7. Children

The App is a professional tool and is not directed to children.

## 8. Changes

Updates to this policy will be posted here with a new "Last updated" date.

## 9. Contact

Questions about this policy: open an issue on the project's repository.
