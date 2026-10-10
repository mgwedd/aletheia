# Signing and notarizing a release

Goal: a DMG that opens with a double-click (no right-click → Open), built and
signed by CI. This is a one-time setup, about 30 minutes plus Apple's
enrollment wait. You need a Mac for steps 2–4.

```
Apple Developer Program ─▶ Developer ID Application cert ─▶ .p12 export
        │                                                        │
        └─▶ app-specific password                                │
                      │                                          ▼
                      └────────▶ scripts/setup-signing-secrets.sh ─▶ 7 GitHub secrets
                                                                     │
                       Release workflow (dry run, then a tag) ◀──────┘
                       build → sign → verify → notarize → staple → publish
```

Without the secrets the release still builds, ad-hoc signed. Nothing breaks
while you do this.

## 1. Enroll in the Apple Developer Program

- Join: <https://developer.apple.com/programs/enroll/> ($99/year).
- An individual enrollment is usually approved within a day or two. An
  organization needs a D-U-N-S number and can take weeks.
- Your 10-character **Team ID** is at
  <https://developer.apple.com/account> → Membership details.
- You must be the **Account Holder** (or an Admin) to create a Developer ID
  certificate.

## 2. Create a "Developer ID Application" certificate

This is the certificate for apps distributed outside the Mac App Store. Not
"Apple Development", not "Mac App Distribution", not "Developer ID Installer".

1. On your Mac open **Keychain Access → Certificate Assistant → Request a
   Certificate From a Certificate Authority**. Enter your email, choose **Saved
   to disk**, and save the `.certSigningRequest`.
2. Go to <https://developer.apple.com/account/resources/certificates/add>,
   choose **Developer ID Application**, upload the request, and download the
   `.cer`.
3. Double-click the `.cer` to install it into your login keychain.
4. In Keychain Access → **My Certificates**, confirm
   `Developer ID Application: Your Name (TEAMID)` appears with a private key
   under it. If there is no key, you are on a different Mac than the one that
   made the request; redo step 1 here.

If it shows "certificate not trusted", install Apple's intermediate
certificates from <https://www.apple.com/certificateauthority/> (Developer ID –
G2).

## 3. Export it as a .p12

1. Keychain Access → **My Certificates** → right-click the Developer ID
   Application certificate → **Export**.
2. Format **Personal Information Exchange (.p12)**. Choose a password. It
   cannot be empty; the workflow imports with it.
3. Export only this one certificate. The script refuses a .p12 holding more
   than one Developer ID Application identity.

## 4. Create an app-specific password (for notarization)

1. <https://account.apple.com> → **Sign-In and Security → App-Specific
   Passwords**.
2. Create one named `aletheia-notary`. Copy it (format `abcd-efgh-ijkl-mnop`).
3. Two-factor authentication must be on for the Apple ID.

The Apple ID used here must belong to the same developer team as the
certificate.

## 5. Set the GitHub secrets

You need the [GitHub CLI](https://cli.github.com) signed in with permission to
edit this repo's secrets.

```sh
gh auth login
scripts/setup-signing-secrets.sh            # defaults to mgwedd/aletheia
```

The script asks for the .p12 path and password, the Apple ID and the
app-specific password. Before it sets anything it:

- imports the .p12 into a throwaway keychain and checks it holds a Developer ID
  Application identity;
- reads the Team ID from the identity name;
- asks Apple (`notarytool history`) whether the Apple ID, Team ID and password
  work.

If any check fails it exits and sets nothing. Secrets travel over stdin to
`gh`; nothing is echoed or written to disk.

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | base64 of the .p12 |
| `MACOS_CERTIFICATE_PWD` | the .p12 password |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Name (TEAMID)` |
| `KEYCHAIN_PASSWORD` | random throwaway for the CI keychain |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | from step 4 |

To set them by hand instead: repo → Settings → Secrets and variables →
Actions → New repository secret.

Delete the .p12 from disk afterwards, or keep it in a password manager. If you
lose both it and the keychain entry, revoke and reissue the certificate.

## 6. Dry run (publishes nothing)

```sh
gh workflow run release.yml --repo mgwedd/aletheia --ref main
gh run watch --repo mgwedd/aletheia
```

Or Actions → Release → **Run workflow**. A run from a branch builds, signs,
verifies, notarizes and staples, then attaches the DMG as the
`aletheia-dryrun-dmg` artifact. Only a tag publishes.

The workflow fails early with a readable message if:

- the signature is not from a Developer ID Application certificate;
- Hardened Runtime is off;
- there is no secure timestamp;
- `get-task-allow` is set.

Notarization usually finishes in 2–15 minutes; the first submission for a new
team can take longer.

## 7. Verify the downloaded DMG on a Mac

Download the artifact, unzip, then:

```sh
xcrun stapler validate Aletheia-*.dmg
spctl --assess --type open --context context:primary-signature --verbose=2 Aletheia-*.dmg
hdiutil attach Aletheia-*.dmg
spctl --assess --type execute --verbose=2 /Volumes/Aletheia/Aletheia.app
codesign -dvv /Volumes/Aletheia/Aletheia.app 2>&1 | grep -E 'Authority|flags|Timestamp'
```

Expect `accepted`, `source=Notarized Developer ID`, an
`Authority=Developer ID Application` line and `flags=...(runtime)`. Then open
it from a quarantined download (Safari or AirDrop) and confirm there is no
Gatekeeper warning.

## 8. Ship

Release tags are cut by `auto-release.yml` (conventional commits → semver). The
next release after the secrets exist is signed and notarized automatically.
Nothing else to change.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Script: "no 'Developer ID Application' identity" | Wrong certificate type exported. Redo step 3 with the Developer ID Application one. |
| Script: "couldn't import the .p12" | Wrong password, or an empty one. |
| Script: "Apple rejected the Apple ID, team ID or app-specific password" | Use the app-specific password, not the Apple ID password. The Apple ID must be on the same team. Apple may also need you to accept new terms at <https://developer.apple.com/account>. |
| `HAS_SIGNING` false, build is ad-hoc | `MACOS_CERTIFICATE` or `MACOS_SIGN_IDENTITY` is missing, or the secret is empty. |
| "MACOS_CERTIFICATE_PWD and KEYCHAIN_PASSWORD must be set" | One is missing. Re-run the script. |
| Notarization "Invalid" | The workflow prints `notarytool log`. Usual causes: unsigned nested binary, no Hardened Runtime, no timestamp. Paste the log into an issue. |
| Notarization hangs | Apple-side queue. Check <https://developer.apple.com/system-status/>. |
| Signed but not notarized | Only some `APPLE_*` secrets are set. All three are needed. |
| Runner job never starts, logs 404 | Runner quota, not a code failure. Re-run later. |
| Gatekeeper warns after install | The DMG is not stapled, or you tested the dry-run artifact from a non-notarized run. Re-check step 7. |

## What I can't do for you

Enrollment, the certificate, the app-specific password and the .p12 export
need your Apple ID and your Mac. Everything after that is scripted. If a step
fails, send the error text from the script or the `notarytool log` output.

## Not covered

- **Sparkle-style update signing.** The in-app updater reads `appcast.json`
  from the GitHub Release; it does not use a separate EdDSA key.
- **Mac App Store.** Different certificates, provisioning and review. Not set
  up.
- **Rotating the certificate.** Developer ID certificates last 5 years. Repeat
  steps 2, 3 and 5 before expiry; nothing else changes.
