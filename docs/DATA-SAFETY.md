# Data safety: never lose the key, never corrupt the data

Two failure modes are catastrophic for a clinician and unacceptable for a
HIPAA-covered record: **losing access to their own data** (a key they can't
recover) and **corrupting their data** (a bad migration in an app update). Both
are worse than the threat encryption defends against, because both destroy the
record itself. This document is the model for avoiding each without a hostile UX.

It is an engineering design reference, not legal advice. It complements
[ENCRYPTION.md](ENCRYPTION.md) (the cipher details) and
[HIPAA-SAFEGUARDS.md](HIPAA-SAFEGUARDS.md) (the §164.312 mapping).

---

## Part 1 — Never lose the key (recoverability)

### The trap to avoid

A single passphrase that is the *only* way to decrypt is maximally secure and
maximally hostile: forget it once and years of clinical records are gone
forever, with no reset and no backdoor. HIPAA calls encryption *addressable*
precisely because unrecoverable ePHI is itself a availability failure
(§164.312(a)(2)(iv) sits next to the contingency-plan requirement
§164.308(a)(7)). The goal is **"encrypted to everyone but the clinician, and the
clinician has more than one way back in."**

### Model: one DEK, many independent unwrap paths (envelope encryption)

All PHI is sealed under one random 256-bit **Data Encryption Key (DEK)**. The
DEK is never stored in the clear; it is stored *wrapped* under one or more
**Key-Encryption Keys (KEKs)**, LUKS-keyslot style. **Any** slot can unwrap the
DEK, so losing one path never locks the clinician out — that is the whole
anti-hostility property.

```
                         ┌──────────────────────────────────────────┐
   PHI files ◀──seal──   │   DEK  (random 256-bit, never on disk raw) │
   (transcripts,         └──────────────────────────────────────────┘
    audio, DB, …)              ▲          ▲              ▲
                               │          │              │
                    unwrap ────┤          ├──── unwrap   ├──── unwrap
                               │          │              │
                    ┌──────────┴──┐  ┌────┴────────┐  ┌──┴───────────────┐
                    │ Device KEK  │  │ Recovery    │  │ CloudKit escrow  │
                    │ (this Mac,  │  │ passphrase  │  │ KEK (future,     │
                    │ Touch ID /  │  │ (password   │  │ opt-in, #60)     │
                    │ account)    │  │  manager)   │  │                  │
                    └─────────────┘  └─────────────┘  └──────────────────┘
                     default, silent   break-glass       trusted off-device
                     tied to macOS ID  human-held        recovery
```

Adding or removing a slot **never re-encrypts a single PHI file** — it only
wraps the same DEK another way. This is exactly the shape the keystore already
has: `Keystore.wrappings: [Wrapping]` with a `kind` per slot
(`Sources/App/Services/Crypto/Keystore.swift`).

### The three paths, and the tradeoffs

| Path | Unlocks when | Lost when | Tradeoff |
| --- | --- | --- | --- |
| **Device KEK** (default) | Every launch on this Mac, gated by the macOS account (and Touch ID where available) | The macOS account/keychain is erased or the clinician moves to a new Mac | Silent and not hostile, but device-bound — must be paired with an off-device path |
| **Recovery passphrase** | The clinician types it (new Mac, keychain reset, restore) | Forgotten *and* the device path is also gone | The break-glass path; low-entropy, so PBKDF2-600k + per-slot salt makes a stolen keystore expensive |
| **CloudKit escrow** (future, opt-in, #60) | Restore on any of the clinician's Macs from their private iCloud | The clinician loses their Apple ID *and* both other paths | Only the *wrapped* DEK (ciphertext) is escrowed; Apple never sees the key or the PHI |

The clinician is locked out only if **every** path they enabled is lost at once.
With device + passphrase (the default after first-run), that means forgetting the
passphrase **and** losing the Mac account simultaneously — and CloudKit escrow
removes even that.

### "Tied to their ID, recoverable via computer auth"

The Device KEK is the request "recoverable unless they fully reset the machine":

- Today: DEK held in the login keychain as a generic password,
  `WhenUnlockedThisDeviceOnly` (never synced, unreadable while the Mac is
  locked), keyed by the keystore's random id
  (`Sources/App/Services/Crypto/DeviceKeyStore.swift`).
- **Hardening (planned):** wrap the keychain item in a `SecAccessControl` with
  `.biometryCurrentSet`/`.userPresence`, so reading the DEK requires a live
  Touch ID or the account password — presence-gated, and auto-invalidated if the
  enrolled biometrics change. This makes "your fingerprint is the key" literally
  true while keeping the passphrase as the portable fallback.
- **Promote the device path to a real keyslot.** Right now the device copy is a
  raw DEK stored beside the keystore rather than a `Wrapping`. Making it a
  first-class `kind: .deviceKey` slot means the keystore alone describes every
  way in, and the Secure Enclave can hold the wrapping KEK rather than the DEK
  itself.

### Non-hostile onboarding rules

1. **Default to two paths.** First-run's opt-out encryption sets a passphrase
   *and* enables the device path ("Remember on this Mac", default on) — one
   silent, one portable, from the very first launch.
2. **Prove the passphrase is saved before it can matter.** After set-up, ask the
   clinician to re-enter it once (confirm they recorded it), and link the exact
   copy for a password manager. Never let a *single* device-only path exist
   without a warning that a machine reset would lose everything.
3. **Make recovery legible.** Settings shows which paths are active ("This Mac ✓,
   Recovery passphrase ✓, iCloud ✗") so the clinician can see their safety net,
   add a path, or rotate the passphrase — all without re-encrypting data.
4. **Never a silent single point of failure.** Turning off the last off-device
   path is a deliberate, warned action (`Keystore.removingWrapping` already
   refuses to remove the last slot).

### HIPAA posture

- Keys never leave the Mac in usable form; the escrow path uploads only
  ciphertext. Transmission-security (§164.312(e)) holds.
- Multiple recovery paths satisfy the *availability* half of the encryption
  safeguard and support the contingency plan (§164.308(a)(7)) without weakening
  confidentiality — each path independently requires either this device's auth
  or a high-entropy-derived KEK.

---

## Part 2 — Never corrupt the data (safe, versioned updates)

### The trap to avoid

No amount of CI can prove an update's migration is correct against *this*
clinician's real data. A migration that runs in place and rewrites the only copy
turns a shipped bug into permanent, silent data loss. The rule: **an update may
never destroy the pre-update data until the clinician has seen the migrated data
and attested it is correct.**

### Model: version the data, snapshot before migrate, prune only on attestation

```
 app update ships new schema
        │
        ▼
 open data folder ──▶ SchemaMigrator.plan(current: user_version)
        │
        ├─ .upToDate            → nothing to do
        ├─ .needsNewerApp       → refuse to open; tell the clinician to update
        │                         (never downgrade-rewrite a newer file)
        └─ .migrate(steps,to)   → 1. SNAPSHOT current data  ──▶  Backups/pre-vN-<ts>
                                  2. apply steps in ONE transaction (all-or-nothing)
                                  3. stamp user_version = to
                                  4. keep the snapshot; DO NOT prune
                                            │
                                            ▼
                          next launch shows: "Updated your records to the new
                          format. Please check they look right."
                                     │                     │
                        "Everything looks good"      "Something's wrong"
                                     │                     │
                          prune snapshots older      Restore: close store,
                          than the last ATTESTED      copy Backups/pre-vN
                          version (keep ≥1 as          over live data, reopen
                          defense in depth)            at the prior version
```

### The pieces, and where they stand

| Piece | Status | Where |
| --- | --- | --- |
| **DB schema version** via `PRAGMA user_version` | **this PR** | `SQLitePersistenceCore` |
| **Ordered, transactional migration runner**; refuse-newer | **this PR** | `SchemaMigrator` (pure, unit-tested) + core |
| **File-format version** for the data folder | in place | `DataSchema` / `StoreMetadata` / `SchemaCompatibility` |
| **Snapshot-before-migrate** (DB via `VACUUM INTO`) — refuse to migrate if the pre-image can't be written | **in place** | `MigrationBackup` (pure policy) + `SQLitePersistenceCore` |
| **Attest-then-prune** UX + **Restore previous version** | next | `MigrationBackup.prunable` ready; needs Settings + a post-update banner |
| **Snapshot the small JSON** (patient/session) alongside the DB | next | copy referenced JSON into the same pre-image set |
| **Whole-folder atomicity** across DB + files | Arch v2 (7), #70 | backup archive covers DB + referenced files |

### Why this is affordable

The expensive PHI (audio, transcripts) is **immutable and referenced by id** — a
migration rewrites the structured DB and small JSON, never the audio. So a
pre-migration snapshot is a `VACUUM INTO` of the SQLite file plus a copy of the
patient/session JSON, not a copy of gigabytes of recordings. Snapshots are
sealed with the same protector as live data (ciphertext at rest) and, per
[HIPAA-SAFEGUARDS.md], excluded from system backups by default.

### Transactional guarantees already in place

- Every migration step runs inside `BEGIN … COMMIT`; any failure rolls back, so
  the schema is either fully at the target version or fully unchanged. SQLite's
  DDL is transactional, and each baseline step is idempotent
  (`CREATE … IF NOT EXISTS`), so an interrupted upgrade re-runs cleanly.
- A newer-than-latest database is refused at open rather than rewritten, so an
  older build can never downgrade-corrupt a file a newer build wrote.

### Interaction with encryption (Part 1)

A snapshot is only useful if it is recoverable. Snapshots are sealed under the
**same DEK** as the live data, so all of Part 1's recovery paths cover them too —
the backup a clinician might need after a bad update is openable by exactly the
keys that open everything else. Losing the passphrase must not orphan the safety
copy, which is another reason the device + escrow paths matter.

---

## Sequencing

1. **This PR** — DB `user_version` + `SchemaMigrator` (ordered, transactional,
   refuse-newer). The versioning foundation for everything above.
2. Snapshot-before-migrate — **done** (`MigrationBackup` + core). Next:
   attest-then-prune + Restore UI, and snapshotting the small JSON too.
3. Device-KEK keyslot hardening (`SecAccessControl` biometrics; promote to a
   `Wrapping`), passphrase-saved confirmation, and the recovery-paths view.
4. CloudKit escrow slot (rides on #60 once CloudKit backup lands).
5. Whole-folder atomic backup (Arch v2 (7), #70).
