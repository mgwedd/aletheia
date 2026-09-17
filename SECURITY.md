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

## Planned

**At-rest encryption of the data folder (opt-in, Tier 2).** Encrypt the SQLite
database, transcripts, summaries, and audio with AES-256-GCM so the files are
ciphertext on disk (protecting against a compromised-while-running Mac and any
synced copies). Key handling uses envelope encryption: a data key unlocked by
Touch ID for daily use, **plus a user-held recovery passphrase** so a backup can
be restored on a new Mac. Trade-off: encrypted files are no longer
Finder-readable plaintext, and the recovery passphrase must be kept safe — a
Secure-Enclave-only key cannot decrypt a backup on different hardware.

## Threat model, briefly

| Scenario | FileVault | App lock | Tier 2 |
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
