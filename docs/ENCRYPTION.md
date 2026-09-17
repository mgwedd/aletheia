# At-rest encryption (Tier 2)

Opt-in AES-256-GCM encryption of the data folder's contents. This document is
the design of record; it is landing in stages (see **Rollout** at the end).

Tier 1 (already shipped) is the Touch ID / password **app lock** — it gates
_opening the running app_. Tier 2 protects the _files on disk_, so the notes
stay unreadable even when someone has the folder but not the app.

## Why, on top of FileVault

FileVault (full-disk encryption) is still the baseline the app recommends, and
it covers the internal drive while the Mac is off. Tier 2 adds protection for
the cases FileVault doesn't:

- the data folder living on an **external / USB drive**,
- a **Time Machine or other backup** copy of it,
- a folder placed inside a **synced directory** (iCloud Drive, Dropbox),
- a Mac **logged in and unlocked** but with FileVault never enabled.

In all of these, the PHI files leave the protection of FileVault; Tier 2 keeps
them ciphertext wherever they land.

## Key hierarchy

```
  recovery passphrase
        │  PBKDF2-HMAC-SHA256 (600k iters, per-keystore random salt)
        ▼
   KEK (key-encryption key, 256-bit, never written to disk)
        │  AES-256-GCM unwrap
        ▼
   DEK (data-encryption key, 256-bit, random, one per folder)
        │  AES-256-GCM seal, fresh 96-bit nonce per file
        ▼
   every PHI file: transcript / summary / chat / patient.json / audio / DB
```

- One random **DEK** encrypts every file. The DEK is generated once per folder
  and **never stored in the clear** — only wrapped.
- The DEK is wrapped in the **keystore** (`<dataRoot>/.aletheia-keystore.json`),
  which can hold **several wrappings of the same DEK** (LUKS-keyslot style). v1
  ships the recovery-passphrase wrapping; a Keychain wrapping (unlock without
  typing the passphrase every launch, protected by the macOS login) drops into
  the same array later without re-encrypting a single file.
- Losing the keystore **and** every passphrase means the data is
  unrecoverable. That is the point of encryption; the UI states it plainly
  before enabling.

## File envelope

Every sealed file has one shape:

```
┌────────┬─────────┬───────────────────────────────────────────────┐
│ magic  │ version │ AES-256-GCM combined box                       │
│ "ALT1" │  0x01   │ nonce(12) ‖ ciphertext(n) ‖ tag(16)            │
└────────┴─────────┴───────────────────────────────────────────────┘
```

- The **GCM tag** authenticates the whole ciphertext: a truncated or tampered
  file fails to open instead of decrypting to garbage.
- The **magic prefix** lets read paths tell a sealed file from a legacy
  plaintext one (`DataCipher.isEnvelope`), so turning encryption on can convert
  files lazily and reads tolerate a half-migrated folder — no flag day.

## Threat model — honest scope

Protects against someone who obtains the **files** without a passphrase / login:
lost or stolen external drive, a leaked backup, a synced copy, a folder copied
off an unattended-but-locked Mac.

Does **not** protect against:

- **Malware or another process running as you while the app is unlocked** — the
  DEK is in memory then, by necessity.
- **A weak passphrase** — PBKDF2 raises the cost of guessing, it doesn't remove
  it. Strength is on the user.
- **Live recording window** — audio is captured to disk first and sealed when
  the recording stops (see Rollout). A crash mid-session can leave that one
  file plaintext until the next clean pass. Everything already saved stays
  sealed.
- **Metadata** — patient/session **folder names and the folder layout** are not
  encrypted (they're how the app finds things). Names are chosen by the user;
  keep identifying detail out of them if that matters.

No custom cryptography: AES-256-GCM and PBKDF2 via Apple's **CryptoKit** and
**CommonCrypto** only. No third-party crypto dependency (supply-chain
constraint). No SQLCipher — the database is protected by the same envelope, not
a third-party SQLite build.

## Rollout (staged PRs)

1. **Crypto core** — `DataCipher` (envelope) + `PassphraseKDF` + `Keystore`,
   with tests. No read/write path touched yet, so existing data is untouched.
   _(this PR)_
2. **Manager + Settings UI** — `EncryptionManager` (enable/disable/unlock,
   set/change passphrase), first-run + Settings surfaces, honest warnings.
3. **Wire text artifacts** — route `Store`'s file I/O through the cipher
   (transcript, summary, chat, `patient.json`), lazy migration on enable.
4. **Wire audio + database** — seal `mic.caf` / `call.caf` on stop; seal the
   comment/notes DB (export-seal on close, open-decrypt on open).
5. **Enable/disable migration + recovery flow** — bulk convert on toggle;
   passphrase-recovery entry point for a fresh Mac.
