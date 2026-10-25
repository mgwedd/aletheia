# Privacy Policy

_Last updated: 2026-10-24_

**Plain-language summary:** Aletheia keeps clinical data in a folder you choose.
A cloud-synced folder may be copied by its provider. Back Up Now saves an
encrypted copy of the database to a folder you choose on your Mac or an external
disk; the App never uploads it. The app itself has no network access: a bundled,
sandboxed helper makes the few outbound requests, and none carries patient data.
Astrea Labs does not collect, receive, store, or
have access to your data or your patients' data. There are no accounts, analytics,
telemetry, or Astrea Labs servers that receive clinical data.

> This document is a template provided for transparency. It is **not legal
> advice**. Because Aletheia is used with protected health information (PHI),
> have your own counsel review this and your practice's privacy notices before
> relying on them.

## 1. Who this covers

This policy describes the Aletheia macOS application ("the App"), made by Astrea Labs LLC,
a Wyoming limited liability company ("Astrea Labs"). It does not
govern model files you choose to download; those are covered by their providers' terms and policies.

## 2. What Astrea Labs collects

The App has no analytics, crash reporting, usage tracking, accounts, or Astrea Labs
backend. Astrea Labs cannot see who uses the App or what it is used for.
Update requests to GitHub, model downloads from Hugging Face and the license
revocation list from `astrealabs.com` may expose an IP address and app version
to those hosts.

If you applied for a license key, Astrea Labs keeps the application you
submitted (your name, contact and professional details, and a record of the key
issued to you), as described on the application form. The App itself never
sends Astrea Labs anything, including your key.

The App also keeps an audit log on your Mac (see section 3). It never leaves
your Mac.

Help > Report a Bug or Request a Feature, the bug button in the sidebar, and the
button in the Aletheia Doctor window open the feedback form at astrealabs.com/feedback in
your web browser. The link carries only the project name, the kind of report,
and an environment line: App version, build tier, macOS version, and whether the
Mac has Apple silicon or an Intel chip. It carries nothing about you, the Mac's
name, or any patient. The App itself sends nothing; whatever you type into the
form is sent by your browser to astrealabs.com, so keep patient information out
of it.

## 3. Where your data is stored

Recordings, transcripts, summaries, notes, comments, medications, clinical
history, and patient information are stored in the data folder you choose. The
folder must be on this Mac. The App defaults to its standard location and refuses
folders in iCloud Drive or another cloud-synced location, network locations and
unencrypted removable drives, so no sync provider copies the data. Production builds do not offer at-rest encryption for new data
folders, so use FileVault and encrypted backup media. The App checks whether the
disk holding the folder is encrypted and does not add new patients, sessions, or
recordings while that disk is known to be unencrypted.

While you record, audio is held in a private staging folder in the App's
Application Support directory (outside the data folder) and moved into the
session folder when the recording stops, sealed if folder encryption is on. If
the App quits unexpectedly, the next launch finishes that step.

The App keeps an append-only audit log in the data folder's database. Each entry
has a time, your macOS account name and user ID, an action (for example app
unlocked, unlock failed, app locked, encryption turned on, off or unlocked,
records exported, patient deleted, recording recovered, audit log exported), and
at most an opaque record ID. It holds no patient names or clinical text. You can
view and export it in Settings > Security.

Settings > Backups > Export All Records copies every patient's notes,
transcripts, comments, and kept recordings into a folder you choose, as ordinary
files that open without the App. The copy is not encrypted by the App, and the
App warns when the destination is on an unencrypted disk or a synced folder.
Keep it on an encrypted disk. The export is written only to the folder you pick.

Settings > Backups > Back Up Now writes an encrypted copy of your whole data
folder (database, notes, transcripts and recordings) to a folder you choose. It needs encryption to be on and
unlocked, refuses synced folders (iCloud Drive, Dropbox and similar), network
locations and unencrypted removable disks, and never uploads the copy. Each
successful run is recorded once in the audit log. Restore from backup (Settings >
Backups) restores a backup into a new, empty folder (never over existing data) and
opens it; it needs your passphrase and the key file kept beside the backup. The App does not upload backups of its own. App
settings, downloaded models, and an optional remembered encryption key are
stored separately in the app container or login Keychain; the audit log's
signing key is in the login Keychain. Your data is not sent to Astrea Labs or a
server it runs.

## 4. Network connections the App makes

The App works offline for its core features. The App itself holds no network
permission. A bundled, sandboxed network helper makes the only outbound
requests, and the App can ask it only for a fixed list of items by number: it
cannot give the helper a web address, text, or data. The helper has no access to
your files. Its network paths are:

- **Update check** — when enabled (the default), and when you choose Check for
  Updates, the helper fetches a version file (an "appcast") from GitHub. Your IP
  address and App version may be visible to the host; no patient data is sent.
- **Update download** — when you choose to install an available update, the
  helper downloads the release disk image from this project's GitHub releases and
  the App checks it against the digest in the version file before opening it.
- **License revocation list** — while update checks are on, the helper
  downloads a signed list of revoked license keys from `astrealabs.com`, at most
  once a day. The request contains no license key or other identifier; your IP
  address and the App version are visible to the host.
- **Model downloads** — when you ask to download a speech-to-text or language
  model, the helper downloads the file from Hugging Face. No patient data is
  uploaded by these requests.
- **Feedback form** — opened in your browser by you (section 2); not a request
  by the App.
- **Local AI** — the built-in AI runs inside the App on this Mac and makes no
  network requests.

A cloud-synced data folder may also be transferred by the provider's sync
software, outside the App's own network requests.

## 5. You are the data controller

You (the clinician or practice) are the controller/custodian and, where
applicable, the HIPAA **covered entity** for the patient data you create with
the App. Because Astrea Labs does not receive PHI through the App, Astrea
Labs is not your business associate for the App itself. You remain
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

Questions about this policy: email support@astrealabs.com.
Never include patient information, recordings, transcripts, notes, or
screenshots that show client details. Use the App's redacted Doctor report
instead. If we receive patient information by mistake, we delete it as far as
we are able.
