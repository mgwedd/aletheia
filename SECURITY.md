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
Machine. Settings › Backup also offers an opt-in end-to-end-encrypted backup
archive (`.aletheiabackup`, sealed with your key) written to a local
`.backups/` folder, plus a staged (not yet live) opt-in encrypted iCloud
destination for the same archive. Point-in-time database snapshots
(`.snapshots/`, via SQLite's `VACUUM INTO`) protect schema migrations and
encryption on/off changes against a mid-write failure.

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
  `transcript.txt`, `summary.txt`, `patient.json`, …). Pure git + grep, no
  third-party scanner; it fails closed on any scanner error.
- **Local pre-commit hook** (`scripts/hooks/pre-commit`): same check before a
  commit is even created. Opt in once with
  `git config core.hooksPath scripts/hooks`.

Also enable **GitHub's native secret scanning + push protection** (Settings →
Code security) for a third layer that blocks known-provider tokens at push time.
Signing/Apple credentials belong in **GitHub Secrets**, never in the tree.
