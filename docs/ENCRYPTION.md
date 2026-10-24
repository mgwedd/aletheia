# At-rest encryption (Tier 2)

Opt-in AES-256-GCM encryption of selected data-folder contents. This feature is
currently available in developer builds only; production builds do not offer to
turn it on. A folder that is already encrypted can still be unlocked, read, and
managed (including turned off) from Settings › Encryption in any build. This document describes the implemented design (see **Rollout**).

Tier 1 (already shipped) is the Touch ID / password **app lock** — it gates
_opening the running app_. Tier 2 seals supported files and database fields
when enabled, so their contents cannot be read from a copied folder without a key.

## Why, on top of FileVault

FileVault (full-disk encryption) is still the baseline the app recommends, and
it covers the internal drive while the Mac is off. Tier 2 adds protection for
the cases FileVault doesn't:

- the data folder living on an **external / USB drive**,
- a **Time Machine or other backup** copy of it,
- a folder placed inside a **synced directory** (iCloud Drive, Dropbox),
- a Mac **logged in and unlocked** but with FileVault never enabled.

In these cases, selected PHI content can leave FileVault's protection. Tier 2
seals supported files and fields; names, metadata, and the database file itself
are not fully encrypted. A synced folder can still expose that information.

## Key hierarchy

```
  passphrase                24-word recovery key
      │ PBKDF2-HMAC-SHA256         │ PBKDF2-HMAC-SHA256
      ▼                            ▼
  KEK (passphrase slot)        KEK (recovery key slot)
      │ AES-256-GCM unwrap         │ AES-256-GCM unwrap
      └──────────────┬─────────────┘
                     ▼
  DEK (data-encryption key, 256-bit, random, one per folder)
         │  AES-256-GCM seal, fresh 96-bit nonce per file
         ▼
  supported PHI files and selected database fields
```

- One random **DEK** encrypts supported content. The DEK is generated once per
  folder and is wrapped by the passphrase and recovery-key slots. If "Remember on this Mac"
  is enabled, a copy is also stored in the device-only login Keychain.
- The DEK is wrapped in the **keystore** (`<dataRoot>/.aletheia-keystore.json`),
  which holds **several wrappings of the same DEK** (LUKS-keyslot style):
  - `.passphrase`: the user's primary passphrase.
  - `.recoveryKey`: a 24-word BIP-39 emergency recovery key (≥256 bits entropy)
    shown once during setup to be printed or saved offline, and replaceable in Settings.
  - Device Keychain: optional transparent auto-unlock on the same Mac.
- Losing the keystore **or** losing both the passphrase and the recovery key means the data is
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
  it. The app requires at least 12 characters (`PassphraseStrength`), normalizes
  the passphrase to Unicode NFC so the same text always derives the same key, and
  slows repeated wrong unlock attempts (three free tries, then a delay that
  doubles up to 15 minutes; `UnlockThrottle`), but a short guessable passphrase
  is still weak. Strength is on the user.
- **Live recording window** — audio is captured to a private (`0700`) `Staging/`
  folder in Application Support and sealed when the recording stops (see
  Rollout). A crash mid-session leaves that staged file unsealed until the next
  launch, when `OrphanAudioSweep` recovers it into its session and seals it.
  Previously sealed content stays sealed.
- **Metadata** — patient/session **folder names and the folder layout** are not
  encrypted (they're how the app finds things). Names are chosen by the user;
  keep identifying detail out of them if that matters.
- **Search index** — `search.sqlite` holds plaintext transcript, note, and comment text
  for search once the folder is unlocked. It is deleted when the encrypted folder
  locks or encryption is turned off and rebuilt on unlock; while the folder is
  unlocked it is on disk and a copied or synced folder includes it.

The encryption implementation uses Apple's **CryptoKit** and **CommonCrypto**.
No SQLCipher is used; the database is an ordinary SQLite file with selected
field values sealed when the feature is enabled.

## What's encrypted

| Data | How |
|------|-----|
| transcript.txt, summary.txt, note.<format>.txt, digest.json, chat.json, patient.json, patient_chat.json | one-shot `DataCipher` envelope, via `FileProtector` in `Store` |
| comment quote/body, note body (Aletheia.sqlite) | field-level (`FieldCipher`, base64 envelope per value); DB file, schema, keys, timestamps stay a normal SQLite file — no SQLCipher |
| mic.caf, call.caf | streaming `ChunkedCipher` (bounded memory), sealed on stop, decrypted to a temp file for transcription |

Not encrypted: patient/session **folder names**, the schema metadata stamp,
the keystore itself, the plaintext search index (`search.sqlite`) while
unlocked, and the audit ledger (`audit_events` in `Aletheia.sqlite`, which holds
no clinical text). Names are how the app finds things;
keep identifying detail out of them if that matters.

## Turning it on / off

Settings → **Encryption** (turning it on is offered in developer builds only). Turning it on sets a passphrase (at least 12 characters), shows the 24-word
recovery key once, and runs `DataMigrator` to seal the folder's existing PHI; turning it off decrypts
everything back to plain files first and only then removes the keystore, so a
failure never leaves data unreadable. If the keystore file goes missing, the
app keeps the folder locked and says so (an enabled marker file records that
encryption was on) rather than treating the sealed files as a plain folder. The DEK is held in memory for the running
session; a fresh launch of an encrypted folder prompts for the passphrase once
(`FolderUnlockView`). Migration is safe to re-run — a keyed protector reads
plaintext and sealed files alike, so a half-converted folder still works.

**Remember on this Mac (optional).** From the unlock gate or Settings the user
can store the DEK in the login keychain (`DeviceKeyStore`,
`WhenUnlockedThisDeviceOnly`, never synced), so the folder auto-unlocks on
launch instead of asking for the passphrase. Locking the encrypted folder drops
the in-memory key and revokes store and worker copies; refreshing the folder
does not reload it. A successful app unlock can explicitly load the remembered
key again. It's a convenience/security
trade-off — anything running as the logged-in user can then reach the key, the
same "malware while unlocked" surface already excluded above — so the toggle is
shown, off by default, both when turning encryption on and at the unlock
gate, and can be turned off at any time; the passphrase is always the fallback. Turning encryption off, or
toggling remember off, deletes the keychain copy.

## Rollout (shipped in stages)

1. **Crypto core** — `DataCipher`, `PassphraseKDF`, `Keystore`.
2. **Manager + choke point** — `EncryptionManager`, `FileProtector` (dormant).
3. **Text + database** — `Store` files and `CommentStore` fields.
4. **Audio** — `ChunkedCipher` streaming seal/open.
5. **UI + migration** — Settings enable/disable, unlock gate, `DataMigrator`.
