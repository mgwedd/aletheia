# Project memory

## Attribution
- Michael Wedd is the sole contributor of record. No Claude attribution anywhere
  in commits or PRs: no `Co-Authored-By: Claude`, `Claude-Session:` trailer,
  "Generated with Claude Code" footer, or model identifiers. If a PR tool appends
  a footer, edit it out of the body afterwards.
- Set git identity to `Michael Wedd` / `michael.wedd@gmail.com` before committing.
- A PR ready for review is a normal open PR, not draft.

## Names and project generation
- Product, target, scheme and Swift module: `Aletheia`; bundle ID
  `com.astrealabs.aletheia`. Sources `Sources/App`, tests `Tests/AletheiaTests`,
  `Tests/AletheiaAcceptance`, `Tests/AletheiaUITests`. macOS 14.
- No `.xcodeproj` is checked in. `project.yml` (XcodeGen) is the source of truth;
  never edit a pbxproj.

## Acceptance criteria and UI tests (`.claude/rules/acceptance-tests.md`)
- `docs/spec/ACCEPTANCE-CRITERIA.md` is the requirements. Every feature or
  substantial change ships a criterion + acceptance test + XCUI test, named by ID.
- Tests change only when behaviour changes. A behaviour-preserving refactor
  touches at most the harness; edited test bodies mean coupling to internals. A
  feature change with untouched acceptance tests means missing coverage.

## Privacy and architecture invariants
- PHI never leaves the Mac. No analytics, telemetry or servers. The app has no
  network entitlement; only the sandboxed XPC `Sources/NetworkHelper` goes
  outbound, and it takes fixed assets by integer ID, never a URL, string or data.
  Never add `network.client` to the app or `URLSession`/sockets outside the helper
  (`scripts/check-entitlements.sh` and `NetworkHelperSourceTests` enforce it).
- The built-in llama.cpp engine is the only AI engine.
- Apple Intelligence stays disabled (`Integrations.appleIntelligenceBlocked = true`);
  don't re-enable unasked.
- No third-party GitHub marketplace Actions; first-party only.

## Conventions
- Patient names on out-of-app surfaces (notifications, menu bar, Spotlight,
  Intents, Calendar, Reminders) go through `PatientLabel`. Enforced by
  `scripts/check-patient-label.sh` and `PatientLabelTests`.
- Colors come from `Theme` (`Sources/App/Views/Theme`), backed by
  `Assets.xcassets/Theme` colorsets. No color literals or system colors in
  screens. New color = colorset + `Theme` token + `Theme.all` entry (+ `pairings`
  entry if text sits on it).
- Text input and selectable text use the Theme text kit (`ThemeTextField`,
  `ThemeTextArea`, `TextField.patient`, `PatientTextView`,
  `.selectablePatientText()`). `WritingToolsBlockTests` rejects raw `TextField`,
  `TextEditor`, `SecureField`, `.textSelection` and `NSTextView` subclasses
  outside `Views/Theme` except its allowlist.
- `AppSettings`: UserDefaults-backed, `private enum Keys`,
  `@Published var x { didSet { defaults.set(...) } }`, loaded in `init`.

## CI and release (procedure: `.claude/skills/release`)
- Releases are automated. Never hand-edit `CHANGELOG.md`, bump Info.plist versions
  (app or `Sources/NetworkHelper`), or tag by hand: `auto-release.yml` does all
  three from conventional commits (`feat` minor, `fix`/`perf`/`revert` patch,
  `!`/`BREAKING CHANGE` major; only docs/tests/markdown changes release nothing).
- A CI job that never ran or whose logs 404 is runner quota, not a regression:
  re-run it.
- `scripts/scan-secrets.sh` is a fail-closed leak gate (secrets and PHI-looking
  filenames). Its `git grep` needs `-e "$PATTERN"` because patterns start with
  `-----BEGIN`.
- Head branches auto-delete on merge, which closes child PRs of that branch.
