# Aletheia — Setup and Troubleshooting

Aletheia has a setup checklist that appears on first launch and walks you
through the data folder, permissions, and model downloads. This guide does
not repeat it. It covers what the checklist assumes, what to do when a step
does not finish, and where to look when something stops working later.

Before recording a real session, read **[CONSENT.md](../CONSENT.md)**.
Consent and licensing-board requirements for recording are your
responsibility; the app does not handle them for you.

## Before you start

- **macOS 14 or newer.** Apple Silicon with 16 GB of memory gives the best
  results. 8 GB works with smaller models, which the app picks for you.
- **Free disk space.** The speech model is roughly 150 MB to 3 GB depending
  on size, and the AI model is about 3 to 6 GB. Both download once.
- **Nothing else to install.** Speech-to-text and the AI model both run
  inside Aletheia, and call audio is captured with a built-in macOS feature,
  so there is no Homebrew, ffmpeg, virtual audio driver, or separate AI app.

## Getting the app

- **Ready-made build:** download the `.dmg` from the
  [Releases page](https://github.com/mgwedd/aletheia/releases) and drag
  Aletheia to Applications.
- **From source:** see the Developer quickstart in the [README](../README.md).

### macOS will not open it

The app is not notarized by Apple, so the first launch is blocked. This is
expected. In Applications, **right-click Aletheia, choose Open, then confirm
Open** in the dialog. After that, double-clicking works.

If there is no Open button, go to **System Settings → Privacy & Security**,
scroll to the message about Aletheia, and click **Open Anyway**.

## Troubleshooting

Start with the built-in checks. They are faster than guessing:

- **Settings → Status** lists in plain language what is ready and what is
  not.
- **Help → Aletheia Doctor** runs a health check of the data folder, the
  database, the encryption key store, snapshots, and the AI engine. Its
  report contains no client information, so it is safe to copy into a
  support request.

### Recording

| Symptom | Likely cause and fix |
|---|---|
| No microphone input | **System Settings → Privacy & Security → Microphone**, turn Aletheia on. Quit and reopen the app. Also check the input device in **System Settings → Sound**. |
| The other person's voice is missing (only "You" lines in the transcript) | Aletheia needs **Screen & System Audio Recording**. Turn it on under **Privacy & Security → Screen & System Audio Recording**, then quit and reopen the app. Aletheia records audio only, never video. |
| Permission is on but still not working | Toggle it off and on again, then restart the app. macOS sometimes keeps a stale grant, especially after an app update or when you move the app to a different location. |
| Call audio is silent | Call audio is the Mac's system audio. If the call plays through a Bluetooth headset or another output device, switch the output and try a short test recording. |
| A reminder appears after 90 minutes | This is the long-recording guard. It asks whether you meant to keep recording. |

### Transcription

| Symptom | Likely cause and fix |
|---|---|
| Transcribe is unavailable | The speech model is not downloaded. Open **Settings → Speech-to-Text Model** and download it. |
| Download fails or stalls | Check your connection and free disk space, then retry. Models are verified against a pinned checksum, so a partial or altered file is rejected rather than used. |
| Slow on a long session | Expected on smaller Macs. A larger model is slower. A smaller one is faster and a little less accurate; change it in Settings. |
| Names or terms are wrong | The transcript is editable. Fix errors in place; summaries and chat use your edited text. |

### Summaries and chat

| Symptom | Likely cause and fix |
|---|---|
| "The AI model isn't downloaded" | Click **Download Model** in the message, or download it under **Settings → AI and models**. Aletheia retries your request when it finishes. |
| Model download fails or stalls | The model is large. Keep the Mac awake and online, check free disk space, and retry. It is verified against a pinned checksum, so a partial file is never used. |
| The first note after opening the app is slow | The model loads into memory first. Later requests in the same session are faster. |
| Slow or low-quality answers | The model may be too large for this Mac's memory (slow) or too small (shallow). Pick another under **Settings → AI and models**. |
| Nothing is generated | The AI model may not be downloaded yet. Download it from the setup checklist or **Settings → AI and models**. |
| A note format looks wrong | Set the format (narrative, SOAP, DAP, BIRP, GIRP) in Settings, then regenerate. |

### Data folder and storage

| Symptom | Likely cause and fix |
|---|---|
| Wrong folder chosen | Change it in Settings. Existing data is not moved for you; copy the folder in Finder if you want it at the new location. |
| "Database cannot be opened" banner | Open Aletheia Doctor from the banner or the Help menu. It names the cause (permissions, a locked or damaged file, a missing key). Pre-migration copies and snapshots live in `<data folder>/.backups/`. |
| Folder is refused (iCloud Drive, Dropbox or other synced folder, network location, unencrypted removable drive) | The data folder must be on this Mac. Click **Use the standard location**, or choose a folder on the Mac's internal disk or an encrypted external drive. If files in an existing folder seem missing, it was probably synced before this check existed: move it to a local folder. See [DATA-SAFETY.md](DATA-SAFETY.md) for how backups treat the data folder. |
| Moved or renamed the data folder | Pick the new location again in Settings. |

### Security and app lock

| Symptom | Likely cause and fix |
|---|---|
| Locked out of the app | The lock uses Touch ID or your Mac login password. If Touch ID fails, use the password prompt. |
| Forgot an encryption passphrase | There is no recovery without the passphrase or the 24-word recovery key shown when encryption was turned on. See [ENCRYPTION.md](ENCRYPTION.md) for what the key store holds and what a lost passphrase means. |

## Backups

Aletheia does not yet make backup copies of its own. Your data folder is
backed up by Time Machine by default; keep those backups on an encrypted
disk. **Settings → Backups → Export All Records** writes a folder of ordinary,
unencrypted files you can keep or hand over; store it somewhere protected. See [DATA-SAFETY.md](DATA-SAFETY.md) for what is and is not covered.

## Updating

The app checks for new versions on launch and when you switch back to it.
The check downloads a small file from GitHub and sends no client data.
To update, choose the update when offered: the app downloads the new `.dmg`
(through its sandboxed network helper, verified before it opens) and you replace
the app in Applications. You can also download the `.dmg` from the Releases page.
**Help → Report a Bug** opens a feedback form in your browser; it carries only
the app, macOS and chip versions, never client data.

## Still stuck

1. Run **Aletheia Doctor** and keep the report.
2. Note your macOS version and Mac model (**Apple menu → About This Mac**).
3. Email support@astrealabs.com with the Doctor report. Do not include client
   names, transcripts, notes, audio, or screenshots that show client details.

## Related

- [README](../README.md): what the app does and how it works
- [CONSENT.md](../CONSENT.md), [PRIVACY.md](../PRIVACY.md), [SECURITY.md](../SECURITY.md)
- [DATA-SAFETY.md](DATA-SAFETY.md), [ENCRYPTION.md](ENCRYPTION.md), [HIPAA-SAFEGUARDS.md](HIPAA-SAFEGUARDS.md)
