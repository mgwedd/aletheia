---
name: release
description: Preflight, trigger, monitor and verify an Aletheia release (signed, notarized DMG via auto-release.yml and release.yml). Use when asked to ship, cut, check or verify a release, or why a release did not happen.
---

# Aletheia release

Never hand-edit `CHANGELOG.md`, bump `Info.plist` (app or `Sources/NetworkHelper`),
or tag by hand.

## Pipeline
1. Push to `main` runs `Smoke Test`. Docs-only pushes (markdown, `docs/`) never start it.
2. On a successful `push` run on `main`, `auto-release.yml` ("Auto Release", ubuntu,
   `release` environment, uses secret `RELEASE_DEPLOY_KEY`) runs
   `scripts/compute-release.sh`. Bump from commits since the last `v*` tag:
   `feat!`/`BREAKING CHANGE` major, `feat` minor, `fix`/`perf`/`revert` patch, anything
   else none. No release if every file changed since the tag is `*.md`, `docs/*` or
   `*Tests/*`. It does nothing if `main` has moved past the tested commit (the newer
   run releases).
3. `scripts/apply-release.sh` stamps both Info.plists and CHANGELOG. The job commits
   `chore(release): vX.Y.Z [skip ci]`, tags `vX.Y.Z`, pushes both, then runs
   `gh workflow run release.yml --ref vX.Y.Z` (the `[skip ci]` tag push starts nothing).
4. `release.yml` ("Release", macos-15, `release` environment, may wait for approval):
   `check-license-keys.sh`, `scripts/build.sh` (signs frameworks, then the XPC helper,
   then the app), checks signature, hardened runtime, no `get-task-allow`, no network
   entitlement on the app but one on the helper, `check-entitlements.sh --app`, packages
   `Aletheia-<ver>.dmg` and `appcast.json`, signs the DMG, notarizes and staples
   (stapling retries, notarization does not), `spctl`, adds `sha256` to `appcast.json`,
   `launch-smoke.sh`, SBOM, provenance attestation, `gh release create`. Assets: DMG,
   `appcast.json`, `Aletheia-<ver>.sbom.cdx.json`.
5. A tag run fails without these `release` environment secrets: `MACOS_CERTIFICATE`,
   `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PASSWORD`, `ASC_API_KEY`, `ASC_API_KEY_ID`,
   `ASC_API_ISSUER_ID`. It also fails while repo variable `ALLOW_UNSIGNED_RELEASE` is
   set (delete it), and publishes only if notarization succeeded.

## Preflight
```
git fetch --tags origin
LAST=$(git describe --tags --abbrev=0 --match 'v*' origin/main)
git log --pretty='%s%n%b' $LAST..origin/main | scripts/compute-release.sh --classify
git diff --name-only $LAST..origin/main | scripts/compute-release.sh --only-ignorable && echo "docs/tests only: no release"
gh run list --branch main --workflow "Smoke Test" --limit 5
```
Needs a green `Smoke Test` push run on the `main` tip. Red with no job started or 404
logs is runner quota: re-run, don't change code.

## Trigger and monitor
- After merge there is nothing to do. Watch with `gh run list --workflow "Auto Release"`,
  then `gh run watch <id> --exit-status`, then the same for `Release`.
- Force a bump or dry-run the version math (no commit or tag):
  `gh workflow run auto-release.yml -f bump=auto|patch|minor|major -f dry_run=true|false`.
  A forced bump releases even docs-only changes.
- Dry-run build, sign and notarize without publishing:
  `gh workflow run release.yml --ref <branch>`. Version is `0.0.0-dryrun`; artifact
  `aletheia-dryrun-dmg` (DMG and SBOM, 3 days).
- Pushing a `v*` tag by hand also starts `release.yml`.
- Local build: `scripts/build.sh` (full Xcode required) writes `dist/Aletheia.app`,
  ad hoc signed unless `CODE_SIGN_IDENTITY` is set.
- Failures: `gh run view <id> --log-failed`. A rejected notarization prints Apple's
  log; a timed-out wait does not cancel the submission (`xcrun notarytool info <id>`).

## Post-release verification (macOS)
```
V=X.Y.Z; D=$(mktemp -d)
gh release view v$V --json assets,tagName,isDraft
gh release download v$V -D "$D"
xcrun stapler validate "$D/Aletheia-$V.dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$D/Aletheia-$V.dmg"
[ "$(shasum -a 256 "$D/Aletheia-$V.dmg" | awk '{print $1}')" = "$(jq -r .sha256 "$D/appcast.json")" ] && echo sha OK
jq '{version,downloadURL,minimumSystemVersion}' "$D/appcast.json"   # version == V
scripts/launch-smoke.sh "$D/Aletheia-$V.dmg"
```
Also check the release notes match the CHANGELOG section and `main` has the
`chore(release): vX.Y.Z [skip ci]` commit.

Report: version and bump reason, run links and conclusions, assets, each verification
result, and what was not verified.
