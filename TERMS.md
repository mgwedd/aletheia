# End User License Agreement and Terms of Service

_Last updated: 2026-10-27_

> This document is **not legal advice**. Aletheia is used with protected health
> information (PHI); have your own counsel review your practice's policies and
> your patient consent process.

## 1. Acceptance

This is an agreement between you and
Astrea Labs LLC, a Wyoming limited liability company ("Astrea Labs", "we", "us").
By installing, opening, or using the Aletheia macOS application ("the App") you
agree to this End User License Agreement and Terms of Service ("Terms") and to
the [Privacy Policy](PRIVACY.md).
If you do not agree, do not use the App.

The App records your acceptance **on your own Mac**: the version of these Terms
you accepted, the date and time, the App version, and (once you have added one)
your license ID and the name the license was issued to. It keeps this in the
App's settings and in a `legal-acceptance.log` file in your data folder that you
can open and read. It does not send that record, or anything else, to Astrea Labs. You
cannot use the App without first accepting; the setup screen will not let you
continue until you do.

That record is a good-faith local log kept for your own reference. It is not
tamper-proof and does not identify who was at the keyboard — no record stored on
your own device can prove either — so treat it as a convenience, not as
independent legal evidence.

## 2. License

The App is proprietary and source-available. Your use is governed by the
[LICENSE](LICENSE). These Terms do not grant any ownership or rights beyond
what that license allows.

**License key.** Making new recordings and using the AI features require a
license key issued to you by Astrea Labs. The key is personal to you: do not share, transfer, or publish it. A
key may have an expiry date, shown in Settings → License key, and can be
renewed. Astrea Labs may revoke a key that is shared or used in breach of
these Terms; the App learns of revocations from a signed list it downloads while
update checks are on, at most once a day, so a revocation takes effect when the
App next receives the list. When a key expires, recording and AI work continue
for a 14-day grace period and then stop; a revoked key has no grace period.

**Your records stay yours.** Opening, reading, searching, exporting and deleting
your existing records never require a license key, with no time limit. After a
key expires or is revoked you can keep using the App for these, and you can
export your records at once (Settings → Backups → Export All Records; see
Exports in section 4 for what it leaves out), so you can always open, read, search, export, and
delete your existing records.

**Pre-release versions.** Beta and other pre-release versions are provided for
evaluation, may contain more errors than a final release, and may change
without notice.

## 3. Not medical advice; not a medical device

The App is a documentation and productivity tool for licensed professionals. It
does **not** provide medical, clinical, diagnostic, or treatment advice, and it
is **not** a medical device. Transcripts and AI-generated summaries can be
inaccurate, incomplete, or misleading. You are the clinician: review, correct,
and take professional responsibility for everything the App produces before
relying on it or entering it into a record.

## 4. Your responsibilities

You are solely responsible for:

- **Consent.** Obtaining informed consent to record, and to process the
  recording with AI, before you start recording, as required by your
  jurisdiction and licensing board. Where the law requires the
  consent of every party to a recording, you are responsible for getting consent from every
  party, including every person on a video call or in the room. The App asks
  you to attest that you have this consent, and saves your attestation with the
  session, but it cannot check that anyone agreed. See [CONSENT.md](CONSENT.md).
- **Your legal obligations.** Your use of the App under HIPAA (where it applies
  to you), state law, and the rules of your licensing board, including lawful
  collection, retention, and disclosure of patient data. You are responsible for
  the patient data you create with the App and, if you are a HIPAA covered
  entity or work for one, for your HIPAA duties, including the App in
  your own risk analysis. Astrea Labs never receives PHI and is not your
  business associate. The App has no special handling for records covered by
  42 CFR Part 2 (substance use disorder treatment programs); if that applies to
  you, it is your responsibility.
- **Device security.** Protecting the Mac the App runs on — FileVault, the App's
  Touch ID / password lock, account security, and physical access. See
  [SECURITY.md](SECURITY.md).
- **Keys and passphrase.** If you turn on data-folder encryption, keeping the
  passphrase (at least 12 characters) and the 24-word recovery key safe and
  separate from the Mac. Astrea Labs cannot recover them, and without them
  encrypted data cannot be recovered.
- **Exports.** Exports the App writes (PDF, Word and Markdown notes, calendar
  files, psychotherapy-note exports, and Export All Records) are plaintext files
  that the App does not encrypt. Export All Records leaves out psychotherapy
  notes and private comments; export those separately. Once an export is
  written, protecting it, sharing only the minimum necessary and only as the law
  allows, and eventually deleting it is your responsibility.
- **Deleting records.** Deleting a patient removes their files and database
  entries from the App, but it is not a secure erase. A deleted patient's
  information can remain in the safety snapshots of the database the App keeps in
  the `.backups` folder of your data folder (the five newest rolling snapshots, and copies made before database changes, which are kept until removed), and in any
  Time Machine or other backups and exports you made. Records may also have to be
  kept for a set period, so check the rules that apply to you before deleting.
- **Supported macOS and updates.** Running the App on macOS 14 or later, and
  installing App updates and macOS security updates. Earlier macOS versions are
  not supported, and an App version you have not updated may lack fixes.
- **Backups.** Backing up your data folder. The App does not back up your data
  for you, and by default it keeps the data folder out of Time Machine and iCloud device backups, so a new installation has no backup until you arrange one.
  Back Up Now (Settings › Backups) saves an encrypted archive of the whole data
  folder, but it needs the App's own encryption, which released versions do not
  include, so it is not available in them. To back up, turn off "Keep my data out
  of Time Machine & iCloud backups" in Settings › Backups and use Time Machine
  with an encrypted backup disk, or copy the data folder to encrypted storage
  yourself, and test a restore. Export All Records is not a complete backup: it
  leaves out psychotherapy notes and private comments, and its files are not
  encrypted by the App (see Exports above).
- **Third-party software.** Any model files you download to use with the App,
  under their own licenses and terms.

## 5. Acceptable use

You may not use the App to violate any law or any patient's rights; to record
anyone without the consent required where you practice; to reverse engineer,
resell, or redistribute the App except as the LICENSE permits; or in a way that
misrepresents the App's output as reviewed clinical advice it has not received.

## 6. No warranty

THE APP IS PROVIDED "AS IS" AND "AS AVAILABLE," WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, ACCURACY, AND
NON-INFRINGEMENT. Astrea Labs does not warrant that the App will be
error-free, that transcription or summaries will be accurate, or that the App
will meet your regulatory obligations.

## 7. Limitation of liability

To the maximum extent permitted by law, Astrea Labs will not be liable for any
indirect, incidental, special, consequential, exemplary, or punitive damages, or
for any loss of data, loss of profits, business interruption, or regulatory
penalties, arising out of or relating to your use of the App.

Because the App runs entirely on your systems and Astrea Labs never receives
or has access to your data, **you are responsible for any breach, loss,
exposure, or exfiltration of data from your own devices, accounts, or backups**,
and Astrea Labs is not liable for it. To the maximum extent permitted by law,
the total liability of Astrea Labs for any claim relating to the App will not
exceed the fees you paid Astrea Labs for the App in the 12 months before the
claim arose (which may be zero).

## 8. Indemnification

To the maximum extent permitted by law, you agree to indemnify and hold harmless
Astrea Labs from any claim, loss, liability, or expense (including reasonable
legal fees) arising out of your use of the App, your data, your recordings, your
patients, or your violation of these Terms or applicable law.

## 9. Third-party components

The App may use open-source and third-party components, each under its own
license. Those licenses govern those components; these Terms govern the App. The
notices are in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in the App
under Settings › Licenses.

## 10. Termination

These Terms apply for as long as you use the App. You may stop using the App at
any time. Astrea Labs may end your right to record and use the AI by revoking
your license key; your access to your existing records continues as described
in section 2. The disclaimers, limitation of liability, and indemnification survive
termination.

## 11. Changes

Astrea Labs may update these Terms. Material changes are published here with a
new "Last updated" date and a new acceptance version; continuing to use the App
after an update requires accepting the updated Terms in the App.

## 12. Governing law

These Terms are governed by the laws of the State of Wyoming, United States,
without regard to conflict-of-laws rules.

## 13. Contact

Questions about these Terms: email support@astrealabs.com.
Never include patient information, recordings, transcripts, notes, or
screenshots that show client details. Use the App's redacted Doctor report
instead, and read it first: redaction removes names, identifiers and file paths
it knows about, but initials and short names can remain. If we receive patient information by mistake, we delete it as far as
we are able and tell you, so you can decide whether it needs assessing under
your own obligations.

Reports sent through the App's Report a Bug or Request a Feature links go to
astrealabs.com. They are reviewed and may be posted as public issues in the
project's GitHub repository, so never put patient or client information in
them.
