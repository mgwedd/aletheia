# Security & data protection

Aletheia handles PHI (session audio, transcripts, notes). Patient data stays on
the Mac: the app itself has no network access, and it protects data at rest in
layers.

## What's in place

**FileVault (checked, required for new records).** Full-disk encryption keyed to
the login password protects everything on the Mac when it's off or logged out
(lost/stolen laptop). It's the main at-rest protection for released builds. Aletheia reads whether
the disk holding your data folder is encrypted (the volume's encryption flag,
read in-process, which works under the App Sandbox). While the disk is known to
be unencrypted, Aletheia won't add new patients, sessions or recordings; existing
records stay readable and exportable. If macOS can't report the state, you can continue and
Aletheia warns once per launch. Settings › Security shows the result and links to
the FileVault pane. It doesn't affect backups.

**App lock (Touch ID / password).** On by default; Settings › Security. While
on, Aletheia requires your Touch ID or Mac password to open and re-locks when
your Mac sleeps or its display sleeps, its screen locks, or you switch user, and
after 15 minutes of inactivity by default (the period is adjustable, or Never).
"Lock when Aletheia is hidden" (on by default) also re-locks on hiding the app
with ⌘H. While locked, every window that shows patient data (the main window, the
patient chat window, Aletheia Doctor, Settings and the Keyboard Shortcuts window)
is covered and hidden from screen capture, so an unlocked, unattended Mac doesn't
expose patient notes through the app. It changes no files and has no effect on
backup or restore. Password fallback is always available, so you can't be locked
out of your own data.

**At-rest encryption of the data folder (opt-in, developer builds only).**
Settings › Encryption can encrypt selected SQLite database fields, transcripts, summaries, and
audio with AES-256-GCM so those files are ciphertext on disk, including in
copied or synced copies of the folder. Key handling uses
envelope encryption: a passphrase of at least 12 characters and a 24-word
emergency recovery key each wrap a per-folder data key, with an optional
Keychain-backed "remember on this Mac" so you aren't prompted every launch.
Repeated wrong passphrases are slowed down (three free attempts, then waits that
double up to 15 minutes). An encrypted folder stays locked until you unlock it,
and one whose keystore file has gone missing stays locked rather than getting a
new key. Trade-off: encrypted files are no longer Finder-readable plaintext, and
the passphrase and recovery key must be kept safe — losing both and any
device-remembered copy makes the data unrecoverable. Production builds do not
offer to turn it on; a folder that is already encrypted can still be unlocked
and managed. The search index (`search.sqlite`) stays plaintext. Full design in
[docs/ENCRYPTION.md](docs/ENCRYPTION.md).

**Backups.** By default Aletheia keeps the data folder out of Time Machine and
iCloud device backups (Settings › Backups), because the folder can hold
unencrypted patient data. Released builds make no backup of their own, so a new
installation has no backup until you arrange one. Either turn off "Keep my data
out of Time Machine & iCloud backups" and back up with Time Machine to an
encrypted disk, or copy the data folder to encrypted storage yourself; then test
a restore. A backup also keeps copies of anything you later delete. Settings ›
Backups › Export All Records copies every patient's background, progress notes,
transcripts, consent records and kept recordings into a folder you choose as
ordinary files that open without Aletheia. Psychotherapy notes and private
comments are left out (export them separately), so it is not a complete backup.
That export is not encrypted by Aletheia: save it to a disk with FileVault on or
an encrypted drive, and avoid synced folders (Aletheia warns about both).
Settings › Backups › **Back Up Now** writes an encrypted archive of the whole data
folder (`.aletheiabackup`, sealed with your encryption key) to a folder you
choose. It needs the App's own encryption to be on and unlocked, which released
builds do not offer, so it is unavailable in them. Where it is available, it
refuses synced folders (iCloud Drive, Dropbox and similar), network locations and
unencrypted removable disks, and never uploads the copy. Restore from backup
unpacks a backup into a new, empty folder, never over existing data, and refuses
a wrong passphrase or an archive that has been altered. Each successful backup and
restore is recorded once in the audit log. Nothing is backed up to iCloud.
Point-in-time database snapshots (`.backups/snapshots/` and
`.backups/migrations/`, via SQLite's `VACUUM INTO`) protect schema migrations,
encryption on/off changes and patient deletion against a mid-write failure; the
five most recent snapshots are kept. All of these live in the single hidden
`.backups/` folder inside your data folder (older versions used `Backups/` and
`.snapshots/`; they are moved there automatically). Because of those snapshots,
deleting a patient does not remove their database entries from `.backups/` right
away, and deleting files on a Mac is not a secure erase.

**Audit log.** A tamper-evident, append-only ledger in the data folder's
database (`Aletheia.sqlite`) records security events and actions on records:
app unlocks, failed unlocks and locks; encryption turned on, off, unlocked or
re-keyed; records viewed, created, amended, deleted, copied and exported (a
session, a note, a patient, or all records); AI use; recording consent
attestations; note signing and AI note verification; recordings recovered after
an unexpected quit; backups and restores; audit-log exports; changes to security
settings or the data folder; export failures; and failed integrity checks. Each
entry has a time, the macOS account name and user ID, and at most an opaque
record ID, never a name or clinical text. Entries are chained with HMAC-SHA256
under a key in the login Keychain, and the database refuses edits and deletes of
the rows. That detects changes made outside the App; it cannot detect changes by
someone who controls your macOS account and Keychain. Writes are best effort, and
a failed write is shown in Settings. Settings › Security lists recent entries,
verifies the chain, and exports a report. The log lives in the data folder and
goes wherever its backups go; export it periodically if your policy requires
keeping it.

**Network access.** The app holds no network entitlement. A bundled, sandboxed
helper makes the only outbound requests, over HTTPS: the update check, the update
download when you choose to install, and opt-in model downloads, to GitHub and
Hugging Face; and a signed list of revoked license keys from astrealabs.com,
fetched at most daily while update checks are on. None of these requests carries
patient information, your license key or an identifier. The app asks it for fixed items by number, never a web address or
data, and the helper has no file access, so no patient data can reach it.
Settings › Security shows what the running copy's signature allows. Help ›
Report a Bug opens a form on astrealabs.com in your browser with only the
project, report type, and app, macOS and chip versions in the link.

**On-device AI.** The built-in model runs inside the app. Apple Intelligence is
turned off on purpose, and macOS Writing Tools is switched off on patient text.
Transcripts and other text the model reads as reference material go into the
prompt in marked blocks, with any look-alike markers broken, so that text can't
pass for instructions.

## Threat model, briefly

The full model, by trust boundary, is in [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md).

| Scenario | FileVault | App lock | At-rest encryption (developer builds only) |
| --- | --- | --- | --- |
| Mac lost/stolen while off | ✅ | — | ✅ |
| Someone opens your unlocked Mac | — | ✅ | ✅ |
| Malware / another process reading the folder while you're logged in | — | — | ◐ |
| A synced (e.g. iCloud) copy of the folder | — | — | ◐ |

◐: sealed files and fields stay ciphertext, but folder names and the search
index (`search.sqlite`) do not, and a key remembered on this Mac or held by the
unlocked app is reachable by software running as you.

### Breach notification and the encryption safe harbor

HHS treats encrypted data as "secured" only when the encryption meets NIST
SP 800-111 and the key or decryption tool has not been compromised. With FileVault
on, a Mac lost while shut down generally meets that. A Mac taken while logged in
or unlocked, a Time Machine or other backup on an unencrypted disk, and exported
files on an unencrypted disk generally do not. Whether a loss is a reportable
breach is your determination under 45 CFR 164.402 to 164.414 and state law, and the
risk assessment is your practice's.

## Keeping secrets & PHI out of the repo

The repo must never contain credentials or patient data. Two layers enforce it:

- **Secret Scan CI gate** (`.github/workflows/secret-scan.yml` → `scripts/scan-secrets.sh`):
  runs on every PR and push and **fails the build** if a commit contains secret
  content (private keys, cloud/API tokens) or a sensitive/PHI filename
  (`.p12`/`.pem`/`.env`/… or the app's runtime artifacts — `*.caf`, `*.sqlite`,
  `transcript.txt`, `summary.txt`, `note.<format>.txt`, `patient.json`, …). Pure git + grep, no
  third-party scanner; it fails closed on any scanner error.
- **Local pre-commit hook** (`scripts/hooks/pre-commit`): same check before a
  commit is even created. Opt in once with
  `git config core.hooksPath scripts/hooks`.

Also enable **GitHub's native secret scanning + push protection** (Settings →
Code security) for a third layer that blocks known-provider tokens at push time.
Signing/Apple credentials belong in **GitHub Secrets**, never in the tree.

## Reporting a vulnerability

Please report security problems privately, not in a public issue or pull
request. On the repository page open the **Security** tab, choose **Report a
vulnerability**, and describe what you found and how to reproduce it. Do not
include real patient data in a report.

## Support without patient data

Astrea Labs support never asks for patient data. Do not send database files,
recordings, transcripts, notes, or screenshots or logs that show client details,
and do not paste any of them into an email or a feedback form.

To report a problem, run **Help → Aletheia Doctor**, copy the report, and email it
to support@astrealabs.com with a short description of what you were doing. The
Doctor report is built to be safe to share: it redacts patient and session names,
identifiers and file paths, and records only checks and error causes. Redaction
works from names and terms it knows, so initials and short names can remain: read
it before you send it.
Do not share your screen with patient data visible.

Reports sent with Help › Report a Bug or Request a Feature go to astrealabs.com,
are reviewed, and may be posted as public issues in the project's GitHub
repository (your email address is not posted). Do not put patient information in
them.

If patient data reaches us by accident, tell us at the same address; we delete it as
far as we are able and tell you, so you can decide whether it needs assessing under
your own obligations.
