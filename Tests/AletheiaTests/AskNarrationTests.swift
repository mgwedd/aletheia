import XCTest
@testable import Aletheia

/// What the Ask status line says, built from what search found, never by a model.
@MainActor
final class AskNarrationTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        SessionSearch.index = SearchIndex()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AskNarrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func coverage(mentions: Int, sessions: Int, date: Date? = nil, terms: [String] = ["dream"]) -> TranscriptCoverage {
        var coverage = TranscriptCoverage(mentions: mentions, searched: true)
        coverage.searchTerms = terms
        coverage.sessionsWithMentions = sessions
        coverage.mentionDate = date
        return coverage
    }

    // MARK: - Searching

    func testSearchingNamesTheSessionsAndTheWords() {
        XCTAssertEqual(PatientAskSteps.gatheringText(sessions: 12, terms: ["dream", "michael"]),
                       "Searching 12 sessions for “dream”, “michael”…")
        XCTAssertEqual(PatientAskSteps.gatheringText(sessions: 1, terms: ["dream"]), "Searching 1 session for “dream”…")
        XCTAssertEqual(PatientAskSteps.gatheringText(sessions: 0, terms: ["dream"]), "Searching the sessions for “dream”…")
        // Nothing to search for: says what is gathered instead.
        XCTAssertEqual(PatientAskSteps.gatheringText(sessions: 7, terms: []),
                       "Searching 7 sessions and gathering summaries and notes…")
    }

    func testALongQuestionNamesItsFirstWordsAndCountsTheRest() {
        XCTAssertEqual(PatientAskSteps.gatheringText(sessions: 4, terms: ["a", "b", "c", "d", "e"]),
                       "Searching 4 sessions for “a”, “b”, “c” and 2 more…")
    }

    func testTheSearchingLineCountsUpAndTheRunCarriesOnFromIt() {
        let asked = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(AIProgressFormat.busyLine("Searching 3 sessions for “dream”…", since: asked, now: asked.addingTimeInterval(4)),
                       "Searching 3 sessions for “dream”… · 0:04")
        // The model starts at 0:05; its line keeps counting from the question.
        var progress = AIRunProgress(readTitle: "Reading what was gathered", startedAt: asked.addingTimeInterval(5))
        progress.runStartedAt = asked
        XCTAssertEqual(AIProgressFormat.statusLine(progress, now: asked.addingTimeInterval(9)),
                       "Reading what was gathered… · 0:09")
    }

    // MARK: - What search found

    func testOneSessionIsNamedByDate() {
        let found = PatientAskSteps.finding(coverage(mentions: 1, sessions: 1, date: date(2026, 10, 13)))
        XCTAssertEqual(found, "1 mention, in the \(date(2026, 10, 13).formatted(.dateTime.month(.abbreviated).day())) session")
    }

    func testSeveralSessionsAreCounted() {
        XCTAssertEqual(PatientAskSteps.finding(coverage(mentions: 5, sessions: 3)), "5 mentions, across 3 sessions")
    }

    func testNoMentionSaysWhichWordsWereMissing() {
        XCTAssertEqual(PatientAskSteps.finding(coverage(mentions: 0, sessions: 0)), "No mention of “dream” in any session")
        XCTAssertEqual(PatientAskSteps.finding(coverage(mentions: 0, sessions: 0, terms: ["dream", "michael"])),
                       "No mention of “dream” or “michael” in any session")
        XCTAssertEqual(PatientAskSteps.finding(coverage(mentions: 0, sessions: 0, terms: ["a", "b", "c"])),
                       "No mention of “a”, “b” or “c” in any session")
    }

    func testSimilarSpellingsCountAsMentions() {
        var similar = coverage(mentions: 0, sessions: 1, date: date(2026, 3, 1))
        similar.similarMentions = 2
        XCTAssertTrue(PatientAskSteps.finding(similar)?.hasPrefix("2 mentions, in the ") == true)
    }

    func testNothingToSearchForSaysNothing() {
        XCTAssertNil(PatientAskSteps.finding(TranscriptCoverage()))
    }

    func testGatheringRecordsWhatSearchFound() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let hit = try store.createSession(for: patient, on: date(2026, 3, 8))
        try store.saveTranscript("[0:10] Call audio: Michaels dream is to sail.", for: patient, session: hit)
        let other = try store.createSession(for: patient, on: date(2026, 3, 1))
        try store.saveTranscript("[0:10] Call audio: Work was busy.", for: patient, session: other)

        let found = store.gatherCitedPatientContext(for: patient, relevantTo: "whats michaels dream", characterBudget: 30_000)
        XCTAssertEqual(found.coverage.searchTerms, ["michaels", "dream"])
        XCTAssertEqual(found.coverage.sessionsWithMentions, 1)
        XCTAssertEqual(found.coverage.mentionDate, date(2026, 3, 8))
        XCTAssertTrue(PatientAskSteps.finding(found.coverage)?.hasPrefix("2 mentions, in the ") == true)

        let missing = store.gatherCitedPatientContext(for: patient, relevantTo: "zeppelin", characterBudget: 30_000)
        XCTAssertEqual(PatientAskSteps.finding(missing.coverage), "No mention of “zeppelin” in any session")
    }

    // MARK: - Background digests

    func testTheDigestLineIsLedByWhatItIsDoingOnce() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let background = AIRunProgress(readTitle: "Reading part 2 of 5", startedAt: t0)
        XCTAssertEqual(
            AIProgressFormat.statusLine(DigestBuilder.statusProgress(background), now: t0.addingTimeInterval(12)),
            "\(DigestBuilder.activityTitle). Reading part 2 of 5… · 0:12")
        // A stage that already names it is not led twice.
        let named = AIRunProgress(readTitle: "\(DigestBuilder.activityTitle) · Reading part 1 of 2", startedAt: t0)
        XCTAssertNil(DigestBuilder.statusProgress(named).lead)
    }

    func testASectionKeepsItsLineWhileItsSummaryIsWritten() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var section = AIRunProgress(readTitle: "Reading section 2 of 5", writeTitle: DigestBuilder.writeTitle, startedAt: t0)
        section.firstTokenAt = t0.addingTimeInterval(5)
        XCTAssertEqual(
            AIProgressFormat.statusLine(DigestBuilder.statusProgress(section), now: t0.addingTimeInterval(12)),
            "\(DigestBuilder.activityTitle). Reading section 2 of 5… · 0:12")
        var merge = AIRunProgress(readTitle: DigestBuilder.mergeTitle, writeTitle: DigestBuilder.writeTitle, startedAt: t0)
        merge.firstTokenAt = t0.addingTimeInterval(5)
        XCTAssertEqual(
            AIProgressFormat.statusLine(DigestBuilder.statusProgress(merge), now: t0.addingTimeInterval(12)),
            "\(DigestBuilder.writeTitle)… · 0:12")
    }

    // MARK: - Notes keep their title and bar

    func testTheNoteLineIsLedByItsTitle() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var progress = AIRunProgress(readTitle: "Reading the session", writeTitle: "Writing the note", startedAt: t0)
        XCTAssertEqual(NoteProgress.statusLine(title: "Generating SOAP note", progress, now: t0.addingTimeInterval(12)),
                       "Generating SOAP note. Reading the session… · 0:12")
        progress.firstTokenAt = t0.addingTimeInterval(20)
        progress.tokensWritten = 64
        XCTAssertEqual(NoteProgress.statusLine(title: "Generating SOAP note", progress, now: t0.addingTimeInterval(30)),
                       "Generating SOAP note. Writing the note… · 0:30")
    }
}
