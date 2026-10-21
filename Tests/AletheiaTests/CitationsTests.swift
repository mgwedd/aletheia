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

    func testMergedAddsLookupSessionsOnceNewestFirst() {
        let lookedUp = [
            CitationSource(tag: "S2", date: day(2026, 1, 5), folderName: "2026-01-05_Session"),
            CitationSource(tag: "S40", date: day(2024, 6, 1), folderName: "2024-06-01_Session"),
        ]
        let merged = Citations.merged(sources(), adding: lookedUp)
        XCTAssertEqual(merged.map(\.tag), ["S1", "S2", "S40"])

        let out = Citations.decorate(answer: "First raised long ago [S40].", sources: merged)
        XCTAssertFalse(out.contains("[S40]"))
        XCTAssertTrue(out.hasSuffix("Sources: June 1, 2024"), out)
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
    func testNothingReadIsNoLabel() {
        XCTAssertNil(TranscriptCoverage().label)
    }

    func testLookupsCountEachSessionOnce() {
        var c = TranscriptCoverage(
            transcriptSessions: 3, sessionsWithPassages: 3, searched: true, digestSessions: 1,
            passageTags: ["S1", "S2", "S3"], digestTags: ["S5"]
        )
        c.addLookups(transcriptTags: ["S1", "S40"], digestTags: ["S5", "S41"])
        c.addLookups(transcriptTags: ["S40"], digestTags: ["S41"])

        XCTAssertEqual(c.sessionsWithPassages, 3, "out of the sessions in the question's range; lookups are counted apart")
        XCTAssertEqual(c.lookupTags, ["S40"])
        XCTAssertEqual(c.digestSessions, 2)
        XCTAssertEqual(
            c.label,
            "Read: digests of 2 sessions · transcript passages from 3 of 3 sessions (0 matches for your words) · follow-up lookups in the transcripts of 1 more session"
        )
    }

    func testLabelPluralsAndSearchCount() {
        let c = TranscriptCoverage(
            transcriptSessions: 22, sessionsWithPassages: 6, notesSessions: 22, unreadableSessions: 0,
            mentions: 14, searched: true, wholeTranscripts: false
        )
        XCTAssertEqual(
            c.label,
            "Read: notes and comments from 22 sessions · transcript passages from 6 of 22 sessions (14 matches for your words)"
        )
        let one = TranscriptCoverage(transcriptSessions: 1, sessionsWithPassages: 1, mentions: 1, searched: true)
        XCTAssertEqual(one.label, "Read: transcript passages from 1 of 1 session (1 match for your words)")
    }

    func testUnreadableSessionsAreLabelledNotRead() {
        let c = TranscriptCoverage(transcriptSessions: 2, sessionsWithPassages: 2, unreadableSessions: 2, wholeTranscripts: true)
        XCTAssertEqual(c.label, "Read: full transcripts of 2 sessions · 2 sessions could not be read, so answers may be incomplete")
    }
}

extension TranscriptCoverageEdgeTests {
    func testNewestFullTranscriptsAndSimilarSpelling() {
        let c = TranscriptCoverage(
            transcriptSessions: 12, sessionsWithPassages: 5, notesSessions: 12, mentions: 7, similarMentions: 2,
            searched: true, fullTexts: true, notesCutSessions: 4
        )
        XCTAssertEqual(
            c.label,
            "Read: notes and comments from 12 sessions (cut short or left out for 4 sessions) · full transcripts of the newest 5 of 12 sessions (7 matches for your words, 2 more with similar spelling)"
        )
    }

    func testSingularForms() {
        let whole = TranscriptCoverage(transcriptSessions: 1, sessionsWithPassages: 1, unreadableSessions: 1, wholeTranscripts: true)
        XCTAssertEqual(whole.label, "Read: full transcripts of 1 session · 1 session could not be read, so answers may be incomplete")
        let newest = TranscriptCoverage(transcriptSessions: 2, sessionsWithPassages: 1, fullTexts: true)
        XCTAssertEqual(newest.label, "Read: the full transcript of the newest session (1 of 2 sessions)")
    }
}

extension TranscriptCoverageEdgeTests {
    func testNothingFitsReadsPlainlyNotNewestZero() {
        let c = TranscriptCoverage(transcriptSessions: 3, sessionsWithPassages: 0, fullTexts: true)
        XCTAssertEqual(c.label, "Read: no full transcripts (not enough room)")
        let cut = TranscriptCoverage(transcriptSessions: 3, sessionsWithPassages: 1, fullTexts: true, newestCutShort: true)
        XCTAssertEqual(cut.label, "Read: the newest session's transcript, cut short (1 of 3 sessions)")
        let none = Prompts.searchBlock(
            SessionSearch.search([], question: "Dana"), shown: 0, whole: false, newest: (0, 3, false), unreadableSessions: 0
        )
        XCTAssertTrue(none.contains("no session transcript is included below"))
        XCTAssertFalse(none.contains("newest 0"))
        let block = Prompts.searchBlock(
            SessionSearch.search([], question: "Dana"), shown: 0, whole: false, newest: (1, 3, true), unreadableSessions: 0
        )
        XCTAssertTrue(block.contains("only the newest session's transcript, cut short to fit, is included below (1 of 3 sessions)"))
    }

    func testSingularMatchSimilarSpellingAndUnreadableWithNewest() {
        let c = TranscriptCoverage(
            transcriptSessions: 4, sessionsWithPassages: 1, unreadableSessions: 1, mentions: 1, similarMentions: 1,
            searched: true, fullTexts: true
        )
        XCTAssertEqual(
            c.label,
            "Read: the full transcript of the newest session (1 of 4 sessions) (1 match for your words, 1 more with similar spelling) · 1 session could not be read, so answers may be incomplete"
        )
        let block = Prompts.searchBlock(
            SessionSearch.search([], question: "Dana"), shown: 0, whole: false, newest: (1, 4, false), unreadableSessions: 1
        )
        XCTAssertTrue(block.contains("only the full transcript of the newest session (1 of 4) is included below"))
    }

    func testSearchingNoticeCountAndPlural() {
        XCTAssertEqual(PatientChatView.searchingNotice(sessions: 0), "Searching…")
        XCTAssertEqual(PatientChatView.searchingNotice(sessions: 1), "Searching 1 session…")
        XCTAssertEqual(PatientChatView.searchingNotice(sessions: 7), "Searching 7 sessions…")
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
