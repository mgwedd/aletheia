import XCTest
@testable import Aletheia

/// The flat global-search list: which sources `Store.searchHits` covers, how
/// hits are titled and counted, and where a query is highlighted.
final class GlobalSearchHitsTests: XCTestCase {
    private var tempRoot: URL!
    private var comments: CommentStore!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlobalSearchHitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        comments = try XCTUnwrap(CommentStore(root: tempRoot))
        store = Store(root: tempRoot, commentStore: comments)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    // MARK: Store.searchHits

    func testEachSourceMapsToItsKind() throws {
        let patient = try store.createPatient(name: "Sam Doe")
        let session = try store.createSession(for: patient, on: date(2026, 10, 8))
        try store.saveTranscript("[00:57] We have been thinking about couples therapy.", for: patient, session: session)
        try store.saveNote("Presenting topics: couples therapy.", for: patient, session: session, format: .soap)
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "Discussed couples therapy vs individual."))
        XCTAssertNotNil(comments.addComment(sessionID: session.id, quotedText: "thinking about it", body: "Raise couples therapy referrals.", anchorSeconds: 57))

        let hits = store.searchHits(query: "couples therapy")
        XCTAssertEqual(SearchHit.counts(hits), [.transcript: 1, .note: 1, .session: 1, .comment: 1])
        XCTAssertEqual(SearchHit.patientCount(hits), 1)

        let titles = Dictionary(uniqueKeysWithValues: hits.map { ($0.kind, $0.title) })
        XCTAssertEqual(titles[.transcript], "Sam Doe, \(SearchHit.dateText(session.date))")
        XCTAssertEqual(titles[.note], "Sam Doe, \(SearchHit.dateText(session.date)) (SOAP)")
        XCTAssertEqual(titles[.comment], "Sam Doe, \(SearchHit.dateText(session.date)) at 0:57")
        XCTAssertEqual(titles[.session], "Sam Doe, \(SearchHit.dateText(session.date))")
        XCTAssertTrue(hits.allSatisfy { $0.session?.id == session.id })
    }

    func testPatientNameMatchIsAPatientHitWithNoSession() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        _ = try store.createPatient(name: "John Smith")
        _ = try store.createSession(for: jane)

        let hits = store.searchHits(query: "jane")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.kind, .patient)
        XCTAssertEqual(hits.first?.patient.id, jane.id)
        XCTAssertNil(hits.first?.session)
        XCTAssertEqual(hits.first?.title, "Jane Doe")
        XCTAssertEqual(hits.first?.snippet, "1 session")
    }

    func testCommentMatchesQuotedPassageWhenBodyDoesNot() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        XCTAssertNotNil(comments.addComment(sessionID: session.id, quotedText: "I stopped taking sertraline", body: "Follow up."))

        let hits = store.searchHits(query: "sertraline")
        XCTAssertEqual(hits.map(\.kind), [.comment])
        XCTAssertTrue(hits[0].snippet.contains("sertraline"))
        // No anchor time, so the title has no " at m:ss".
        XCTAssertFalse(hits[0].title.contains(" at "))
    }

    func testEachFormatsNoteIsItsOwnHit() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveNote("Subjective: insomnia.", for: patient, session: session, format: .soap)
        try store.saveNote("Data: insomnia.", for: patient, session: session, format: .dap)

        let hits = store.searchHits(query: "insomnia")
        XCTAssertEqual(hits.filter { $0.kind == .note }.compactMap(\.noteLabel).sorted(), ["DAP", "SOAP"])
        // The mirrored summary.txt must not add a third "note".
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(Set(hits.map(\.id)).count, 2)
    }

    func testLegacySummaryIsSearchedWhenNoFormatNoteExists() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveSummary("Client is planning a vacation.", for: patient, session: session)

        let hits = store.searchHits(query: "vacation")
        XCTAssertEqual(hits.map(\.kind), [.note])
        XCTAssertEqual(hits.first?.noteLabel, "Summary")
    }

    func testAllTermsMustMatchWithinOnePlace() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("couples came up", for: patient, session: session)
        try store.saveNote("therapy was discussed", for: patient, session: session, format: .narrative)

        XCTAssertTrue(store.searchHits(query: "couples therapy").isEmpty)
        XCTAssertEqual(store.searchHits(query: "couples").map(\.kind), [.transcript])
    }

    func testPatientsAreAlphabeticalAndSessionsNewestFirst() throws {
        let bob = try store.createPatient(name: "Bob")
        let amy = try store.createPatient(name: "Amy")
        let older = try store.createSession(for: bob, on: date(2026, 9, 1))
        let newer = try store.createSession(for: bob, on: date(2026, 9, 24))
        let amys = try store.createSession(for: amy, on: date(2026, 9, 10))
        for (patient, session) in [(bob, older), (bob, newer), (amy, amys)] {
            try store.saveTranscript("insurance question", for: patient, session: session)
        }

        let hits = store.searchHits(query: "insurance")
        XCTAssertEqual(hits.map(\.patient.name), ["Amy", "Bob", "Bob"])
        XCTAssertEqual(hits.compactMap(\.session?.id), [amys.id, newer.id, older.id])
    }

    func testEmptyQueryReturnsNothing() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("some content", for: patient, session: session)
        XCTAssertTrue(store.searchHits(query: "").isEmpty)
        XCTAssertTrue(store.searchHits(query: "  ,. ").isEmpty)
    }

    // MARK: Titles and counts

    func testClockText() {
        XCTAssertEqual(SearchHit.clockText(0), "0:00")
        XCTAssertEqual(SearchHit.clockText(57), "0:57")
        XCTAssertEqual(SearchHit.clockText(61.9), "1:01")
        XCTAssertEqual(SearchHit.clockText(3665), "61:05")
        XCTAssertEqual(SearchHit.clockText(-4), "0:00")
    }

    func testKindLabelsFollowChipOrder() {
        XCTAssertEqual(SearchKind.allCases.map(\.filterLabel), ["Patients", "Sessions", "Transcripts", "Notes", "Comments"])
        XCTAssertEqual(SearchKind.allCases.map(\.badge), ["Patient", "Session", "Transcript", "Note", "Comment"])
    }

    // MARK: SearchHighlighter

    private func marked(_ text: String, _ query: String) -> [String] {
        SearchHighlighter.ranges(of: query, in: text).map { String(text[$0]) }
    }

    func testRangesAreCaseAndDiacriticInsensitiveAndCoverEveryOccurrence() {
        XCTAssertEqual(marked("Couples therapy and COUPLES again", "couples"), ["Couples", "COUPLES"])
        XCTAssertEqual(marked("Café culture", "cafe"), ["Café"])
    }

    func testRangesCoverEachTermAndMergeOverlaps() {
        XCTAssertEqual(marked("couples therapy helps", "therapy couples"), ["couples", "therapy"])
        // "ther" is inside "therapy": one merged range, not two.
        XCTAssertEqual(marked("therapy", "ther therapy"), ["therapy"])
    }

    func testNoRangesForEmptyQueryOrNoMatch() {
        XCTAssertTrue(marked("anything", "").isEmpty)
        XCTAssertTrue(marked("anything", "  ").isEmpty)
        XCTAssertTrue(marked("anything", "zebra").isEmpty)
        XCTAssertTrue(marked("", "zebra").isEmpty)
    }

    func testSegmentsRebuildTheTextAndFlagMatches() {
        let text = "Raise couples therapy referral options."
        let segments = SearchHighlighter.segments(in: text, query: "couples therapy")
        XCTAssertEqual(segments.map(\.text).joined(), text)
        XCTAssertEqual(segments.filter(\.isMatch).map(\.text), ["couples", "therapy"])
        XCTAssertEqual(segments.first, SearchHighlighter.Segment(text: "Raise ", isMatch: false))
        XCTAssertEqual(SearchHighlighter.segments(in: "plain", query: "zebra"), [SearchHighlighter.Segment(text: "plain", isMatch: false)])
    }
}
