# Acceptance execution layer

How each check in [ACCEPTANCE-CRITERIA.md](ACCEPTANCE-CRITERIA.md) is proven, and
how "accepted" is decided: a check is accepted when its fitness function passes
in CI. Nothing else counts, and a pending test is not accepted.

## The pyramid

```
                 ACCEPTANCE-CRITERIA.md       one line per check · product words · stable IDs
                ─────────────────────────
               BEHAVIOR-REFERENCE.md          edge cases · exact copy · pointers into the source
             ─────────────────────────────
            Tests/AletheiaAcceptance          fitness functions · DSL only · one per check
          ─────────────────────────────────
         Tests/AletheiaTests                  unit tests · free to change with internals
```

Each fact lives in one place and everything else refers to it by ID:

| Fact | Lives only in | Referred to by |
|---|---|---|
| What a check promises | ACCEPTANCE-CRITERIA.md | its ID (`EXPORT-03`) |
| Edge cases, exact copy | BEHAVIOR-REFERENCE.md | its ID (`EXP-029`) |
| Which edge cases a check rolls up | BEHAVIOR-REFERENCE.md (`qa:` tag on each item) | |
| How a check is exercised | the fitness function | |

A fitness function has no comment restating its check. `AcceptanceCase` reads
the sentence from ACCEPTANCE-CRITERIA.md at run time and puts it in the failure
message, so a red test reads like the QA line it broke.

## The rule

A fitness function talks only to the domain DSL (Given, When, Then). It never
names an app type, view, file layout or function. When internals change, only
what sits under the DSL changes; the QA line and its test stay the same.

```swift
final class ExportSpec: AcceptanceCase {
    func test_EXPORT_07() async throws {
        try await given.encryptionIsOn()
        try await given.patients(1, eachWith: .sessions(1))
        try await given.appIsLocked()
        let destination = try given.emptyFolder()

        let attempt = try await when.exportAllRecords(to: destination)

        try then(attempt).wasRefused()
        try then(destination).isEmpty()
    }
}
```

## One subject: the real app

Every fitness function runs through XCUITest against the Debug `Aletheia.app`.
Unit tests remain the fast layer for internals.

**Hermetic fixture mode.** The app has a fixture mode, compiled in Debug only; a
Release guard test fails if any fixture symbol or launch key is reachable in
Release. In it every nondeterministic input is pinned:

| Input | Fixture |
|---|---|
| Time | A fixed clock the test can advance |
| Microphone and call audio | A named synthetic clip |
| Transcription | The clip's paired transcript |
| AI engine | A scripted engine that also records the context it received |
| Keychain, Touch ID, FileVault | In-memory keychain; biometric result and FileVault state set per scenario |
| Data folder, defaults | Fresh for every launch, inside the app's own container |
| Locale, time zone, appearance, animations | Pinned; animations off |
| Network | None (the app has no network entitlement) |

**Given is a seed scenario.** The test passes a JSON scenario in the launch
environment (patients, sessions, notes, encryption, locked, and so on) and the
app builds that state before its first window appears. When steps go through the
real UI only. A step that ends "on next launch" terminates and relaunches the
app on the same data folder.

**Then is UI assertions plus a probe.** Outcomes on screen are asserted through
accessibility identifiers, which are part of the driver contract. Outcomes that
are not on screen (files written, plaintext or not, audit rows, audio cleaned
up, what the AI engine received) are read from an invisible, Debug-only
accessibility element whose value is a JSON snapshot of probe facts. The test
reads the probe through XCUITest and never reads the app's container directly.

Fitness functions are written to the expectation, never to the current code. A
known bug is written as the intended behavior and its test simply fails until
the fix lands. `XCTExpectFailure` is not allowed. `try pending("reason")` is
allowed, so coverage can grow journey by journey.

## Coverage test and ledger

Both live inside the test run, in Swift, in `Tests/AletheiaAcceptance/Ledger/`.

**`SpecCoverageTests`** parses the two docs and enumerates the test methods that
exist at runtime (the `AcceptanceCase` subclasses and their `test_` selectors).
It fails on:

- a check with no test, a test with no check, or a duplicate ID;
- a reference item whose `qa:` tag names no check, or a check with no reference item;
- a check under another journey's heading, or a check line without exactly one `→`;
- a `Copy` entry no test uses;
- `XCTExpectFailure` anywhere in the suite.

Its parser is unit-tested with small good and bad doc fixtures in the same bundle.

**The ledger.** An `XCTestObservation` observer writes `acceptance-ledger.md`
and `acceptance-ledger.json` when the bundle finishes, into the directory named
by `ACCEPTANCE_LEDGER_DIR` (a temp directory when unset). Each check is passed,
failed or pending, with its sentence and any failure message. The headline is
"Accepted: N of M checks", counting passed only, with pending and failed checks
listed by ID under it. CI appends the Markdown to the job summary and uploads
both files.

Pending does not fail the job; the ledger keeps it visible. Whether pending
blocks a release is a separate call.

## CI

One `acceptance` job on a standard `macos-15` runner, sharded by journey with a
matrix, each shard selecting its specs with `-only-testing`. The coverage test
runs in its own shard and finishes in seconds. Docs-only changes still run it,
because the docs are what it checks. A final cheap job merges the shard ledgers
into the summary. Only first-party, SHA-pinned actions are used.

## Flake policy

No fixed delays and no retries. A fixed delay (`Task.sleep`, `Thread.sleep`, a
"settle" pause) is never a wait: it is either too short, so flaky, or too long,
so slow. Everything that waits goes through one helper in `DSL/Eventually.swift`:

```swift
func eventually(
    within timeout: TimeInterval = 5,
    _ what: String,
    _ condition: @MainActor () async throws -> Bool
) async throws
```

It polls about every 10 ms and throws, naming `what`, if the condition has not
held after `within` seconds. The coverage test rejects a fixed delay anywhere in
`DSL/` or `Drivers/` other than that file. In UI code, wait on an element with
a timeout. A flaky test is a bug in the fixture or the app; fix the root cause.

## Harness

How the two layers stay fast and independent of each other and of earlier runs.

- **One scripted model, one scenario.** `Sources/App/FixtureMode/ScriptedModel.swift`
  answers both layers: rules matched by a marker in the request, fallback
  replies, held steps released one by one (a release with nothing held is kept
  for the next hold), and `waitUntilAsked(count:)` instead of polling.
  `FixtureScenario` is the one Codable scenario; the acceptance suite seeds it
  in process and the UI driver passes it as JSON at launch.
- **Teardown stops work.** Each acceptance test ends by stopping every AI
  request, releasing every held step and resetting app statics, and keeps going
  after a failed check (`continueAfterFailure`) so one failure cannot hang the
  rest. The test clock never starts in the first hour of a day. The scratch
  folder sits beside the data folder, never inside it.
- **Quiet fixture UI.** In fixture mode live timelines stop ticking and motion
  is reduced, and the probe is computed off the main actor and published only
  when its JSON changes.
- **Find by identifier.** UI tests find controls by accessibility identifier
  (`chat.ask-field`, `chat.send`, `ai.status`, `notes.generate` and so on),
  wait until a control is hittable before clicking, and paste long text rather
  than typing it. `waitForProbe` decodes a probe value only when it changes and
  fails the test when it times out.
- **Say what was seen.** `eventually(..., describe:)` adds the last observed
  state to its timeout. A UI wait that times out attaches a screenshot and the
  element tree.
- **Isolated runs.** `scripts/run-tests.sh <scheme>` takes a lock so only one
  run uses the Mac at a time, gives each run its own derived data, result
  bundle and ledger folder under `build/runs/`, and sets per-test limits (60 s,
  120 s for a test that asks). Each UI launch ends any running copy of the app,
  ignores saved window state, and fixture folders older than a day are removed.
- **UI shards.** CI runs the UI classes in three shards of similar length;
  the last runs every class the others don't name. A job named "UI tests"
  passes only when all shards pass. A behavior the acceptance suite proves in
  process isn't proved again slowly in XCUI, but every check keeps a UI test.

## Layout

```
docs/spec/ACCEPTANCE-CRITERIA.md          the checks (source of truth)
docs/spec/BEHAVIOR-REFERENCE.md           detail, each item tagged qa:
Tests/AletheiaAcceptance/
  DSL/        Given.swift When.swift Then.swift Copy.swift Eventually.swift
  Ledger/     SpecCoverageTests.swift AcceptanceLedger.swift
  <Journey>/  <Journey>Spec.swift          one file per walkthrough section
```

`project.yml` is the source of truth for the targets. No Cucumber or Gherkin:
the spec is Markdown and the DSL is plain Swift, per the first-party-only rule.
