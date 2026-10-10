import XCTest
@testable import Aletheia

final class CitationsTests: XCTestCase {
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func sources() -> [CitationSource] {
        [
            CitationSource(tag: "S1", date: date(2026, 3, 5), folderName: "2026-03-05_Session"),
            CitationSource(tag: "S2", date: date(2026, 1, 5), folderName: "2026-01-05_Session"),
        ]
    }

    func testCitedSourcesReturnsOnlyReferencedSessions() {
        let cited = Citations.citedSources(in: "She raised it again [S1], first noted earlier.", from: sources())
        XCTAssertEqual(cited.map(\.tag), ["S1"])
    }

    func testCitedSourcesIgnoresUnknownTags() {
        let cited = Citations.citedSources(in: "Per [S9] and [S2].", from: sources())
        XCTAssertEqual(cited.map(\.tag), ["S2"], "invented tags shouldn't appear as sources")
    }

    func testCitedSourcesPreservesNewestFirstOrder() {
        let cited = Citations.citedSources(in: "Both [S2] and [S1] discuss it.", from: sources())
        XCTAssertEqual(cited.map(\.tag), ["S1", "S2"], "ordered by the source list (newest first), not answer order")
    }

    func testDecorateReplacesTagsInlineAndAppendsSources() {
        let out = Citations.decorate(answer: "Her sleep improved [S1] after the change [S2].", sources: sources())
        XCTAssertFalse(out.contains("[S1]"))
        XCTAssertFalse(out.contains("[S2]"))
        XCTAssertTrue(out.contains("Mar 5, 2026"))      // inline medium date
        XCTAssertTrue(out.contains("Jan 5, 2026"))
        XCTAssertTrue(out.contains("Sources: "))
        XCTAssertTrue(out.contains("March 5, 2026"))    // footer long date
    }

    func testDecorateWithNoCitationsIsUnchangedAndHasNoFooter() {
        let answer = "I don't see that discussed in the recorded sessions."
        let out = Citations.decorate(answer: answer, sources: sources())
        XCTAssertEqual(out, answer)
        XCTAssertFalse(out.contains("Sources:"))
    }

    func testDecorateLeavesUnknownTagsUntouched() {
        let out = Citations.decorate(answer: "Maybe [S9]?", sources: sources())
        XCTAssertTrue(out.contains("[S9]"), "unknown tag left as-is")
        XCTAssertFalse(out.contains("Sources:"), "no real session cited")
    }
}

extension CitationsTests {
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func twelve() -> [CitationSource] {
        (1...12).map { CitationSource(tag: "S\($0)", date: day(2026, 12 - ($0 - 1), 1), folderName: "f\($0)") }
    }

    // A tag must match whole: "[S1]" is not inside "[S10]".
    func testTagMatchingIsExactSoS1DoesNotMatchS10() {
        let all = twelve()
        XCTAssertEqual(Citations.citedSources(in: "See [S10].", from: all).map(\.tag), ["S10"])
        let out = Citations.decorate(answer: "See [S10].", sources: all)
        XCTAssertTrue(out.contains("(Mar 1, 2026)"), "S10 is March 1")
        XCTAssertFalse(out.contains("Dec 1, 2026"), "S1's date must not appear")
    }

    func testRepeatedTagIsReplacedEverywhereAndListedOnce() {
        let out = Citations.decorate(answer: "Yes [S1]. Again [S1].", sources: sources())
        XCTAssertFalse(out.contains("[S1]"))
        XCTAssertEqual(out.components(separatedBy: "(Mar 5, 2026)").count - 1, 2)
        XCTAssertEqual(out.components(separatedBy: "March 5, 2026").count - 1, 1, "footer lists the session once")
    }

    func testFooterIsNewestFirstEvenWhenTheAnswerCitesOlderFirst() {
        let out = Citations.decorate(answer: "Earlier [S2], later [S1].", sources: sources())
        let footer = out.components(separatedBy: "Sources: ").last ?? ""
        XCTAssertEqual(footer, "March 5, 2026; January 5, 2026")
    }

    func testAdjacentTagsAreBothResolved() {
        let out = Citations.decorate(answer: "Noted [S1][S2].", sources: sources())
        XCTAssertTrue(out.contains("(Mar 5, 2026)(Jan 5, 2026)"))
    }

    func testTagsAreCaseSensitive() {
        let out = Citations.decorate(answer: "Maybe [s1]?", sources: sources())
        XCTAssertEqual(out, "Maybe [s1]?")
    }

    func testEmptyInputs() {
        XCTAssertEqual(Citations.decorate(answer: "", sources: sources()), "")
        XCTAssertEqual(Citations.decorate(answer: "Per [S1].", sources: []), "Per [S1].")
        XCTAssertTrue(Citations.citedSources(in: "", from: sources()).isEmpty)
    }

    func testDecorateIsStableWhenRunTwice() {
        let once = Citations.decorate(answer: "Per [S1].", sources: sources())
        XCTAssertEqual(Citations.decorate(answer: once, sources: sources()), once, "already-decorated text has no tags left to rewrite")
    }

    // The gate the chat view applies: without the module the answer is untouched.
    func testDisplayShowsRawAnswerWhenModuleIsAbsent() {
        let raw = "Her sleep improved [S1]."
        XCTAssertEqual(Citations.display(answer: raw, sources: sources(), enabled: false), raw)
    }

    func testDisplayDecoratesWhenModuleIsPresent() {
        let out = Citations.display(answer: "Her sleep improved [S1].", sources: sources(), enabled: true)
        XCTAssertTrue(out.contains("Sources: March 5, 2026"))
    }

    func testDisplayFollowsTheRegistryForEachTier() {
        for tier in [BuildTier.production, .preview, .dev] {
            let registry = FeatureRegistry.compose(tier: tier, from: FeatureRegistry.allModules)
            let enabled = registry.contains(id: SourceCitationsFeatureModule.id)
            let out = Citations.display(answer: "x [S1]", sources: sources(), enabled: enabled)
            XCTAssertTrue(out.contains("Sources:"), "citations footer expected at \(tier)")
        }
    }
}

final class TranscriptCoverageEdgeTests: XCTestCase {
    func testNothingReadableIsNotPartialAndShowsFull() {
        let c = TranscriptCoverage()
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(c.percentIncluded, 100)
        XCTAssertNil(c.notice)
    }

    func testIncludedAboveTotalIsCappedAt100AndNotPartial() {
        let c = TranscriptCoverage(sessions: 1, sessionsWithoutPassages: 0, totalCharacters: 100, includedCharacters: 150)
        XCTAssertFalse(c.isPartial)
        XCTAssertEqual(c.percentIncluded, 100)
    }

    func testNoticeMentionsSessionsWithoutPassagesOnlyWhenThereAreSome() {
        let none = TranscriptCoverage(sessions: 3, sessionsWithoutPassages: 0, totalCharacters: 1000, includedCharacters: 500)
        XCTAssertEqual(none.notice?.contains("session(s) had no transcript passage"), false)
        let some = TranscriptCoverage(sessions: 3, sessionsWithoutPassages: 2, totalCharacters: 1000, includedCharacters: 500)
        XCTAssertEqual(some.notice?.contains("2 of 3 session(s) had no transcript passage included"), true)
    }
}

final class CitedContextTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testCitedContextTagsSessionsNewestFirstAndMapsThem() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("A weekend of kayaking.", for: patient, session: jan)
        let mar = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("She spoke about her grief.", for: patient, session: mar)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "grief")

        // Newest session is S1.
        XCTAssertEqual(context.sources.first?.tag, "S1")
        XCTAssertEqual(context.sources.first?.folderName, mar.folderName)
        XCTAssertEqual(context.sources.map(\.tag), ["S1", "S2"])

        // The tag is embedded in the context the model sees.
        XCTAssertTrue(context.text.contains("[S1]"))

        // And it round-trips: a model answer citing [S1] resolves to March.
        let cited = Citations.citedSources(in: "Per [S1].", from: context.sources)
        XCTAssertEqual(cited.first?.folderName, mar.folderName)
    }

    func testCitedContextSkipsEmptyTranscripts() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try store.createSession(for: patient, on: date(2026, 2, 1)) // no transcript saved
        let withText = try store.createSession(for: patient, on: date(2026, 2, 2))
        try store.saveTranscript("Discussed medication.", for: patient, session: withText)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "medication")
        XCTAssertEqual(context.sources.map(\.tag), ["S1"], "only sessions with transcripts get tags")
        XCTAssertEqual(context.sources.first?.folderName, withText.folderName)
    }
}
