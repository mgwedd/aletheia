# Threat model

What Aletheia protects, who it protects it from, and what it leaves to the Mac.
It describes what the code does today; the protections in use are listed in
[SECURITY.md](../SECURITY.md).

## What is protected

- **Patient records**: patient and session folders, the SQLite database, notes,
  comments.
- **Recordings and transcripts**: `mic.caf`, `call.caf`, `transcript.txt`,
  summaries and chats.
- **Keys**: the passphrase-wrapped data key and its keystore file, the optional
  copy in the login Keychain, and the 24-word recovery key (shown once, kept by
  the user). The key that seals the audit ledger lives in the login Keychain.
- **Audit ledger**: the record of unlocks, exports and deletions (no clinical
  text).

## Trust boundaries and threats

### The main app

The app holds no network entitlement, has no telemetry, and loads models only
from files on disk.

| Threat | What the app does |
| --- | --- |
| Patient data sent off the Mac | The app cannot open a socket. `scripts/check-entitlements.sh` and the source-scanning tests fail the build if a network entitlement or `URLSession` appears outside the helper. |
| Text in a transcript or document steering the model | Reference text goes into the prompt in marked blocks, with look-alike markers broken. |
| Cloud AI seeing patient text | The only AI engine is the built-in llama.cpp. Apple Intelligence and macOS Writing Tools are off for patient text. |
| A corrupted or truncated sealed file or keystore | Parsing is bounded and authenticated (AES-256-GCM); a damaged file fails to open instead of decrypting to garbage. |
| A deleted keystore treated as "no encryption" | A folder that was encrypted stays locked until its keystore is restored. |
| Guessing the passphrase | At least 12 characters, PBKDF2-HMAC-SHA256, and growing delays after three wrong tries. The recovery key is a separate 256-bit secret. |
| Quiet edits to the audit ledger | Entries are chained with HMAC-SHA256 under a Keychain key, the database refuses edits and deletes of the rows, and Settings verifies the chain. |

### The network helper

`Sources/NetworkHelper` is a bundled, sandboxed XPC service. It is the only code
that can reach the network. It has no file access, no app group and no Keychain
access; the app hands it a write-only file handle for each download.

- **What it may fetch**: a compiled-in table of pinned model files (Whisper
  from `ggerganov/whisper.cpp` at a fixed commit; the Llama and Gemma GGUF files
  from `ggml-org` at fixed commits), the update feed
  (`appcast.json` of the latest GitHub release), and the release archive named
  by that feed when it is a release asset of this repository.
- **How it is asked**: the app sends an integer asset ID. No URL, string or
  data crosses the connection.
- **Limits**: https only, on GitHub and Hugging Face hosts (and the CDNs they
  redirect to); plain GET with no body, cookies, cache or credentials; a
  redirect that leaves the host list is refused; the feed is capped at 256 KB.

| Threat | What happens |
| --- | --- |
| The app (or a bug in it) asks for an arbitrary address | It cannot; there is no way to name one. |
| The helper is abused to read or leak data | It has nothing to read and no way to send anything but the fixed GET requests above. |
| A feed or redirect points at an attacker's host | Refused by the host list and the release-asset path check. |

### Model files and updates

- **Models** are downloaded only when the user opts in. In the app, not in the
  helper, the file's SHA-256 is compared with a digest pinned in the app. A
  mismatch deletes the file; an unverified file is never at its final path, and
  a model with no pinned digest cannot be downloaded. The bundled runtime
  (llama.cpp) is pinned and checked in CI.
- **Updates**: the helper fetches the feed and the disk image named in it, and
  the app checks the image against the digest in that feed before opening it.
  The user installs by dragging the new copy in; nothing replaces the app
  silently. The digest comes from the same feed, so it catches corruption and a
  swapped file on a CDN, not a compromise of the release itself. That depends
  on the repository's own release controls.

### The Mac's own protections

Aletheia relies on these and does not replace them.

- **FileVault** covers a lost or stolen Mac. The app reads the disk's
  encryption flag and, while the disk is known to be unencrypted, does not add
  new patients, sessions or recordings.
- **App lock** (Touch ID or password) covers an unattended Mac: it locks on
  sleep, screen lock, user switch and inactivity, covers every window that shows
  patient data, and hides them from screen capture.
- **Keychain** holds the ledger key and, only if the user chooses "remember on
  this Mac", a device-only copy of the data key.
- **At-rest encryption** is opt-in and, in production builds, only manages an
  already-encrypted folder. Where on, it keeps a copied, synced or backed-up
  folder unreadable without a key. Folder names and the search index
  (`search.sqlite`) are not sealed. See [ENCRYPTION.md](ENCRYPTION.md).

## Out of scope

- **A compromised macOS account, or malware running with the user's
  privileges.** It can read what the user can read, including the unlocked data
  key in memory and a remembered Keychain key.
- **Physical access to an unlocked Mac** with Aletheia unlocked. App lock and
  FileVault cover the locked cases only.
- **A weak or shared passphrase, or a lost passphrase and recovery key** (the
  data is then unrecoverable by design).
- **Anything the user exports.** Exported records and the unencrypted copies
  the user chooses to make are ordinary files on the disk they pick.
- **The release repository's own account security.**
