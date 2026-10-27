# Privacy Policy

_Last updated: 2026-10-27_

**Plain-language summary:** Aletheia keeps clinical data in a folder you choose.
A cloud-synced folder may be copied by its provider. By default the App keeps
that folder out of Time Machine and iCloud device backups and, in released versions,
makes no backup of its own, so arranging a backup is up to you (section 3). The
app itself has no network access: a bundled,
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

The App has no analytics, crash reporting, usage tracking or accounts, and it
never tells Astrea Labs how or when it is used.
Update requests to GitHub, model downloads from Hugging Face and the license
revocation list from `astrealabs.com` may expose an IP address and standard
request details, such as the App and macOS versions, to those hosts.

If you applied for a license key, Astrea Labs keeps the application you
submitted (your name, contact and professional details, and a record of the key
issued to you), as described on the application form. The App itself never
sends Astrea Labs anything, including your key.

The App also keeps an audit log on your Mac (see section 3). It never leaves
your Mac. It writes operational messages to the macOS system log; these hold
identifiers and error descriptions, not patient names or note text.

Help > Report a Bug or Request a Feature, the bug button in the sidebar, and the
button in the Aletheia Doctor window open the feedback form at astrealabs.com/feedback in
your web browser. Reports are reviewed and may then be posted as public issues in
the project's GitHub repository (your email address is not posted), so never put
patient or client information in one. The link carries only the project name, the kind of report,
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
folders, so use FileVault and encrypted backup media. The data folder also holds a
search index (`search.sqlite`) of the words in your records, including psychotherapy
notes, and in released builds it is not encrypted by the App. The App checks whether the
disk holding the folder is encrypted and does not add new patients, sessions, or
recordings while that disk is known to be unencrypted.

While you record, audio is held in a private staging folder in the App's
Application Support directory (outside the data folder) and moved into the
session folder when the recording stops, sealed if folder encryption is on. If
the App quits unexpectedly, the next launch finishes that step. Once a recording
is transcribed, the App deletes the audio. If transcription produces no text, it
keeps the audio so you can retry, unencrypted unless folder encryption is on, and
you can delete it yourself. Keeping audio after transcription is available only
with folder encryption on.

Each session also stores a record of the recording consent you attested (who
consented, by what method, when, which Mac user recorded it, and, for a parent,
guardian or other representative, their name) in a `consent.json` file in the
session folder. A session's note can be signed; the signature (a hash of the
note's text, the signer and the time) is stored with it.

Each session has a progress note, which belongs in the clinical record, and an
optional psychotherapy note for your private process notes. The App keeps
psychotherapy notes out of Export All Records and out of every AI prompt, and
exports them only on their own. Whether a note counts as psychotherapy notes under
45 CFR 164.501 depends on what it contains and on your keeping it separate from
the rest of the record. Diagnosis, treatment plan, symptoms, progress and session
times belong in the progress note. Transcripts used to write a note are likely
part of your designated record set, and so subject to patients' access requests
(45 CFR 164.524) and your retention rules; decide that under your own policy.

The App keeps an append-only audit log in the data folder's database. Each entry
has a time, your macOS account name and user ID, an action, and at most an opaque
record ID. Actions include unlocking and locking the App and failed unlocks;
turning encryption on or off and changing its key; viewing, creating, amending,
deleting, copying and exporting records; AI use; recording consent attestations;
note signing; recovered recordings; backups and restores; exporting the log;
changes to security settings or the data folder; export failures; and failed
integrity checks. It holds no patient names or clinical text. Entries are chained
so the App can detect changes made outside it; that cannot detect changes by
someone who controls your macOS account. Writes are best effort, and a failed
write is shown in Settings. The log lives in the data folder and goes wherever the
folder's backups go; export it from Settings > Security if your policy requires
keeping it. You can view and export it there.

Settings > Backups > Export All Records copies every patient's background,
progress notes, transcripts, consent records and kept recordings into a folder you
choose, as ordinary files that open without the App. Psychotherapy notes and
private comments are not included; export them separately from the patient page. The copy is not encrypted by the App, and the
App warns when the destination is on an unencrypted disk or a synced folder.
Keep it on an encrypted disk. The export is written only to the folder you pick.

**Backups.** By default the App keeps the data folder out of Time Machine and
iCloud device backups, because the folder can hold unencrypted patient data, and it
makes no backup of its own in released versions. A new installation therefore has
no backup until you arrange one: turn off "Keep my data out of Time Machine & iCloud backups" in Settings > Backups and back up to an encrypted disk, or copy the
folder to encrypted storage yourself. A backup also keeps whatever you later
delete.

Deleting a patient removes their files and database entries from the App, but it
is not a secure erase. The App first saves a safety copy of its database in the
`.backups` folder inside the data folder (it keeps the five most recent), which
still holds the deleted patient's database entries until newer copies replace it,
and Time Machine or other backups and exports you made may hold earlier copies.

Settings > Backups > Back Up Now writes an encrypted copy of your whole data
folder (database, notes, transcripts and recordings) to a folder you choose. It
needs the App's own encryption to be on and unlocked, which released versions do
not offer, so it is unavailable in them. It refuses synced folders (iCloud Drive, Dropbox and similar), network
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
  address and standard request details, such as the App and macOS versions, may be
  visible to the host; no patient data is sent.
- **Update download** — when you choose to install an available update, the
  helper downloads the release disk image from this project's GitHub releases and
  the App checks it against the digest in the version file before opening it.
- **License revocation list** — while update checks are on, the helper
  downloads a signed list of revoked license keys from `astrealabs.com`, at most
  once a day. The request contains no license key or other identifier; your IP
  address and standard request details, such as the App and macOS versions, are
  visible to the host. If you turn update checks off, the App does not pick up
  revocations.
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
The App has no special handling for records covered by 42 CFR Part 2; if it
applies to you, that is your responsibility.

## 6. Security

Protecting the data on your Mac is your responsibility. Enable **FileVault**,
use the App's **Touch ID / password lock**, keep your backups on encrypted media,
and restrict physical and account access to the computer. HHS treats encrypted data as
"secured" for breach purposes only if the encryption meets NIST SP 800-111 and the
key was not compromised. FileVault on a Mac lost while shut down generally meets
that; a Mac taken while logged in, an unencrypted backup disk, and exported files
on an unencrypted disk generally do not. Whether a loss must be reported is your
determination. If the selected folder is
cloud-synced, protect that account. See [SECURITY.md](SECURITY.md).

## 7. Children

The App is a professional tool and is not directed to children.

## 8. Changes

Updates to this policy will be posted here with a new "Last updated" date.

## 9. Contact

Questions about this policy: email support@astrealabs.com.
Never include patient information, recordings, transcripts, notes, or
screenshots that show client details. Use the App's redacted Doctor report
instead, and read it first: redaction removes names, identifiers and file paths
it knows about, but initials and short names can remain. If we receive patient information by mistake, we delete it as far as
we are able and tell you, so you can decide whether it needs assessing under your
own obligations.
