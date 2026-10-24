# Acceptance execution layer

How each check in [ACCEPTANCE-CRITERIA.md](ACCEPTANCE-CRITERIA.md) gets an
executable fitness function that survives refactors and can't quietly go stale.

## The pyramid

```
                 ACCEPTANCE-CRITERIA.md       QA walkthrough · ~200 checks · product words
                ─────────────────────────
               BEHAVIOR-REFERENCE.md          edge cases · exact copy · evidence paths
             ─────────────────────────────
            Tests/AletheiaAcceptance          fitness functions · DSL only · 1 per check
          ─────────────────────────────────
         Tests/AletheiaTests                  unit tests · free to change with internals
```

Each layer says something the one above doesn't, and nothing is written twice:

| Fact | Lives only in | Everything else refers to it by |
|---|---|---|
| What a check promises (the sentence) | ACCEPTANCE-CRITERIA.md | its ID (`EXPORT-03`) |
| Edge cases, exact copy, where in the source | BEHAVIOR-REFERENCE.md | its ID (`EXP-029`) |
| Which edge cases a check rolls up | BEHAVIOR-REFERENCE.md (`qa:` tag on each item) | — |
| How a check is exercised | the fitness function | — |
| How the app is driven | the drivers | — |

So a fitness function has no doc comment restating its check. `AcceptanceCase`
reads the sentence from ACCEPTANCE-CRITERIA.md at run time and puts it in the
failure message, so a red test reads like the QA line it broke.

## The rule

A fitness function may only talk to the **domain DSL**. It never names an app
type, view, file layout or function. When internals change, only a **driver**
changes; the QA line and its fitness function stay the same. The DSL grows
only when a new product behavior needs a new verb.

## Example

```swift
// Tests/AletheiaAcceptance/Export/ExportSpec.swift
final class ExportSpec: AcceptanceCase {
    func test_EXPORT_03() async throws {
        try await given.patients(3, eachWith: .sessions(2), .notes)
        let destination = try given.emptyFolder()

        try await when.exportAllRecords(to: destination, cancellingAfter: .firstFile)

        try then(destination).isEmpty()
    }

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
// Failure: "EXPORT-07 Lock the app, then try Export All Records → it refuses and writes nothing.
//           expected destination to be empty, found 2 files"
```

## Drivers

| Driver | Backs | How | Lane |
|---|---|---|---|
| **InProcess** | most checks | The real app graph (settings, encryption, stores, coordinators) over a throwaway data folder, with hardware swapped for fixtures: scripted `LocalLLMEngine`, fixture `Transcribing`, synthetic audio, injectable clock, in-memory keychain. Drives the same model actions the views call. | every PR |
| **UI** | checks whose promise *is* the UI (a button exists, a lock covers the window) | XCUITest against the Debug app with a fixture data folder. Accessibility identifiers on the controls the DSL touches are part of the driver contract. | every PR (small set), full nightly |
| **Artifact** | promises about the shipped build | Inspects the Release `.app`: entitlements, signature, linked frameworks, bundled assets, helper allow-list. Absorbs the `scripts/check-*.sh` gates. | every PR + release |
| **Probes** | side effects | Read-only observers the other drivers attach: data-folder watcher (what was written, plaintext or not), network observer, notification / Spotlight / pasteboard capture, audit-log reader. | with their driver |

A nightly real-model lane runs small pinned Whisper and GGUF models on fixture
audio for checks about AI output. Those check properties (sections present,
citations resolve, no names absent from the transcript), never exact text.

On-screen text is matched through one DSL copy table (`Copy.exportReady`, …),
so a wording change is one DSL line plus the reference entry.

## Staleness gate

`scripts/check-spec-coverage.sh` (bash + Python, runs in the Linux sandbox and
CI) fails the build when any layer drifts from the one above it:

- a QA check with no `test_<ID>`, a `test_<ID>` with no QA check, or a duplicate;
- a reference item whose `qa:` tag names no QA check, or a QA check no
  reference item rolls up (a promise with no recorded detail);
- a reference `evidence:` path that no longer exists, or a line range past the
  end of the file — the usual sign a behavior moved or was deleted;
- a `Copy` entry no test uses.

A known bug is written as the intended behavior and tagged `⚠ DEFECT` in the
reference; its fitness function wraps the check in `XCTExpectFailure`, so the
suite stays green until the fix lands and then fails until the tag is removed.
Tests never lock a bug in.

`try pending("reason")` is allowed so coverage can grow journey by journey; the
script prints a per-journey table of passing / pending / missing. Because the
sentence and its test are tied by ID, editing one without the other shows up
together in review.

## Layout

```
docs/spec/ACCEPTANCE-CRITERIA.md          QA walkthrough (source of truth)
docs/spec/BEHAVIOR-REFERENCE.md           detail + evidence, each item tagged qa:
Tests/AletheiaAcceptance/
  DSL/        Given.swift When.swift Then.swift Copy.swift Fixtures/
  Drivers/    InProcessDriver.swift UIDriver.swift ArtifactDriver.swift Probes/
  <Journey>/  <Journey>Spec.swift                one file per walkthrough section
Tests/AletheiaUITests/                    XCUITest host for the UI driver
scripts/check-spec-coverage.sh
```

`project.yml` gains an `AletheiaAcceptance` unit-test bundle (hosted by the app)
and an `AletheiaUITests` UI-testing bundle. No Cucumber/Gherkin: the spec stays
Markdown and the DSL is plain Swift, per the first-party-only rule.

The existing unit tests can be rewritten, merged or deleted as internals change;
the acceptance suite is what must stay green. Unit tests that only restate an
acceptance check can be dropped over time.
