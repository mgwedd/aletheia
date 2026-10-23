# Security & data protection

Aletheia handles PHI (session audio, transcripts, notes). Patient data stays on
the Mac: the app itself has no network access, and it protects data at rest in
layers.

## What's in place

**FileVault (checked, required for new records).** Full-disk encryption keyed to
the login password protects everything on the Mac when it's off or logged out
(lost/stolen laptop). It's the HIPAA-standard baseline. Aletheia reads whether
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
"Lock when Aletheia is hidden" (off by default) also re-locks on hiding the app
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

**Backups.** The data folder backs up with zero configuration via macOS Time
Machine (keep those backups on an encrypted disk — the folder can hold
unencrypted data; Settings › Backups can exclude it if you prefer). Aletheia
does not make or upload backup copies of its own, but Settings › Backups ›
Export All Records copies every patient's notes, transcripts, comments and kept
recordings into a folder you choose as ordinary files that open without
Aletheia. That export is not encrypted by Aletheia: save it to a disk with
FileVault on or an encrypted drive, and avoid synced folders (Aletheia warns
about both). An end-to-end-encrypted
archive (`.aletheiabackup`, sealed with your key) for a local
`.backups/archives/` folder and an encrypted iCloud destination are built but
not connected to the app. Point-in-time database snapshots
(`.backups/snapshots/` and `.backups/migrations/`, via SQLite's `VACUUM INTO`)
protect schema migrations and encryption on/off changes against a mid-write
failure. All of these live in the single hidden `.backups/` folder inside your
data folder (older versions used `Backups/` and `.snapshots/`; they are moved
there automatically).

**Audit log.** A tamper-evident, append-only ledger in the data folder's
database (`Aletheia.sqlite`) records app unlocks, failed unlocks and locks;
encryption turned on, off or unlocked; records exported (a session, a note, a
patient, or all records); a patient or a set-aside recording deleted; a recording
recovered after an unexpected quit; and audit-log exports. Each entry has a time,
the macOS account name and user ID, and at most an opaque record ID, never a name
or clinical text. Entries are chained with HMAC-SHA256 under a key in the login
Keychain, and the database refuses edits and deletes of the rows. Settings ›
Security lists recent entries, verifies the chain, and exports a report. Other
actions, such as viewing or editing a note, are not recorded.

**Network access.** The app holds no network entitlement. A bundled, sandboxed
helper makes the only outbound requests: the update check, the update download
when you choose to install, and opt-in model downloads, over HTTPS to GitHub and
Hugging Face. The app asks it for fixed items by number, never a web address or
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

| Scenario | FileVault | App lock | At-rest encryption |
| --- | --- | --- | --- |
| Mac lost/stolen while off | ✅ | — | ✅ |
| Someone opens your unlocked Mac | — | ✅ | ✅ |
| Malware / another process reading the folder while you're logged in | — | — | ◐ |
| A synced (e.g. iCloud) copy of the folder | — | — | ◐ |

◐: sealed files and fields stay ciphertext, but folder names and the search
index (`search.sqlite`) do not, and a key remembered on this Mac or held by the
unlocked app is reachable by software running as you.

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
