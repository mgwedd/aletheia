# Security & data protection

Aletheia handles PHI (session audio, transcripts, notes). It's local-only —
nothing leaves the Mac — and it protects data at rest in layers.

## What's in place

**FileVault (recommended).** Full-disk encryption keyed to the login password
protects everything on the Mac when it's off or logged out (lost/stolen laptop).
It's the HIPAA-standard baseline. macOS can't expose FileVault status to a
sandboxed app, so Aletheia can't verify it — Settings › Security links you
straight to the FileVault pane, and turning it on is strongly recommended. It
doesn't affect backups.

**App lock (Touch ID / password).** Optional, in Settings › Security. When on,
Aletheia requires your Touch ID or Mac password to open and re-locks when it's
hidden, so an unlocked, unattended Mac doesn't expose patient notes through the
app. It changes no files and has no effect on backup or restore. Password
fallback is always available, so you can't be locked out of your own data.

**At-rest encryption of the data folder (opt-in, "Extra Encryption").** Settings
can encrypt the SQLite database's text columns, transcripts, summaries, and
audio with AES-256-GCM so the files are ciphertext on disk (protecting against
a compromised-while-running Mac and any synced copies). Key handling uses
envelope encryption: a recovery passphrase you set wraps a per-folder data key,
with an optional Keychain-backed "remember on this Mac" so you aren't prompted
every launch. Trade-off: encrypted files are no longer Finder-readable
plaintext, and the recovery passphrase must be kept safe — losing it and any
device-remembered copy makes the data unrecoverable. Full design in
[docs/ENCRYPTION.md](docs/ENCRYPTION.md).

**Backups.** The data folder backs up with zero configuration via macOS Time
Machine (keep those backups on an encrypted disk — the folder can hold
unencrypted data; Settings › Backups can exclude it if you prefer). Settings ›
Backups also has **Back up now**, which writes an end-to-end-encrypted archive
of the database (`.aletheiabackup`, sealed with your encryption key) to a folder
you choose. It refuses iCloud Drive and other synced or network folders, and
needs encryption to be on and unlocked. Point-in-time database snapshots
(`.backups/snapshots/` and `.backups/migrations/`, via SQLite's `VACUUM INTO`)
protect schema migrations and encryption on/off changes against a mid-write
failure. All of these live in the single hidden `.backups/` folder inside your
data folder (older versions used `Backups/` and `.snapshots/`; they are moved
there automatically).

## Threat model, briefly

| Scenario | FileVault | App lock | Extra Encryption |
| --- | --- | --- | --- |
| Mac lost/stolen while off | ✅ | — | ✅ |
| Someone opens your unlocked Mac | — | ✅ | ✅ |
| Malware / another process reading the folder while you're logged in | — | — | ✅ |
| A synced (e.g. iCloud) copy of the folder | — | — | ✅ |

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
