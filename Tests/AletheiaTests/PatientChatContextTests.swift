import CryptoKit
import XCTest
@testable import Aletheia

/// What the patient-wide chat sees beyond transcripts: generated notes, the
/// therapist's own notes and comments, a visible marker for a transcript that
/// can't be read, and citations limited to sessions actually in the context.
final class PatientChatContextTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatientChatContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// The text under the header tagged `tag`, up to the next session header.
    private func section(_ text: String, tag: String) -> String {
        guard let start = text.range(of: "===== Session [\(tag)]") else { return "" }
        let rest = text[start.upperBound...]
        if let next = rest.range(of: "===== Session [") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    /// A transcript of `lines` filler lines that never mention "kayaking".
    private func filler(lines: Int) -> String {
        (0..<lines)
            .map { "[00:\(String(format: "%02d", $0 % 60))] Patient: We talked about the weather and errands today." }
            .joined(separator: "\n")
    }

    private func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    // MARK: - Notes, generated notes and comments

    func testNotesAndCommentsAppearUnderTheirOwnSessionHeader() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("January transcript text.", for: patient, session: jan)
        let mar = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("March transcript text.", for: patient, session: mar)

        try store.saveNote("March generated body.", for: patient, session: mar, format: .soap)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: mar.id, text: "She seemed brighter today.")
        _ = annotations.addComment(sessionID: mar.id, quotedText: "March", body: "revisit next week")
        annotations.saveNote(sessionID: jan.id, text: "January therapist note.")

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")

        // The newest session is S1.
        let newest = section(context.text, tag: "S1")
        XCTAssertTrue(newest.contains("March transcript text."))
        XCTAssertTrue(newest.contains("Generated progress note (SOAP):"))
        XCTAssertTrue(newest.contains("March generated body."))
        XCTAssertTrue(newest.contains("Therapist's session notes:"))
        XCTAssertTrue(newest.contains("She seemed brighter today."))
        XCTAssertTrue(newest.contains("Therapist's margin comments on the transcript:"))
        XCTAssertTrue(newest.contains("revisit next week"))
        XCTAssertFalse(newest.contains("January"), "another session's material must not leak under this header")

        let oldest = section(context.text, tag: "S2")
        XCTAssertTrue(oldest.contains("January transcript text."))
        XCTAssertTrue(oldest.contains("January therapist note."))
        XCTAssertFalse(oldest.contains("March generated body."))
        XCTAssertFalse(oldest.contains("revisit next week"))
    }

    func testResolvedCommentsAreLeftOut() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Some transcript.", for: patient, session: session)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        let comment = try XCTUnwrap(annotations.addComment(sessionID: session.id, quotedText: "", body: "closed out point"))
        annotations.setCommentResolved(id: comment.id, resolved: true)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")
        XCTAssertFalse(context.text.contains("closed out point"))
    }

    func testLegacySummaryIsIncludedWhenNoPerFormatNoteExists() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Some transcript.", for: patient, session: session)
        try store.saveSummary("Older summary text.", for: patient, session: session)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")
        XCTAssertTrue(section(context.text, tag: "S1").contains("Older summary text."))
        // Reading for the chat must not adopt the summary into a format file.
        let adopted = store.sessionDir(for: patient, session: session)
            .appendingPathComponent(Store.noteFileName(for: .narrative))
        XCTAssertFalse(FileManager.default.fileExists(atPath: adopted.path))
    }

    func testEachFormatsNoteIsLabelled() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Some transcript.", for: patient, session: session)
        try store.saveNote("soap body", for: patient, session: session, format: .soap)
        try store.saveNote("birp body", for: patient, session: session, format: .birp)

        let text = section(store.gatherCitedPatientContext(for: patient, relevantTo: "x").text, tag: "S1")
        XCTAssertTrue(text.contains("Generated progress note (SOAP):\nsoap body"))
        XCTAssertTrue(text.contains("Generated progress note (BIRP):\nbirp body"))
    }

    func testSessionWithOnlyANoteAndNoTranscriptIsStillIncluded() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: session.id, text: "Phone check-in, no recording.")

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "x")
        XCTAssertEqual(context.sources.map(\.folderName), [session.folderName])
        XCTAssertTrue(section(context.text, tag: "S1").contains("Phone check-in, no recording."))
    }

    // MARK: - Ranker exclusions

    /// Three sessions whose combined transcripts outgrow the retriever budget,
    /// with only the newest mentioning "kayaking". Returns (jan, feb, mar).
    private func makeRankedHistory(_ patient: Patient) throws -> (SessionRecord, SessionRecord, SessionRecord) {
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript(filler(lines: 60), for: patient, session: jan)
        let feb = try store.createSession(for: patient, on: date(2026, 2, 5))
        try store.saveTranscript(filler(lines: 60), for: patient, session: feb)
        let mar = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("[00:00] Patient: A weekend of kayaking helped.", for: patient, session: mar)
        return (jan, feb, mar)
    }

    func testNotesAreIncludedEvenWhenTheRankerExcludesTheTranscript() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let (jan, _, _) = try makeRankedHistory(patient)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: jan.id, text: "January therapist note.")
        try store.saveNote("January generated body.", for: patient, session: jan, format: .dap)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking")

        // Newest first: Mar = S1, Feb = S2, Jan = S3.
        XCTAssertTrue(section(context.text, tag: "S1").contains("kayaking"))
        let januarySection = section(context.text, tag: "S3")
        XCTAssertTrue(januarySection.contains("January therapist note."))
        XCTAssertTrue(januarySection.contains("January generated body."))
        XCTAssertFalse(januarySection.contains("weather"), "the ranker still decides which transcript text is kept")
    }

    func testCitationSourcesListOnlySessionsSentInTheContext() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let (jan, feb, mar) = try makeRankedHistory(patient)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: jan.id, text: "January therapist note.")

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking")

        // Feb's transcript was dropped by the ranker and it has no other
        // material, so it is neither in the text nor a citable source.
        XCTAssertEqual(context.sources.map(\.folderName), [mar.folderName, jan.folderName])
        XCTAssertFalse(context.sources.contains { $0.folderName == feb.folderName })
        XCTAssertFalse(context.text.contains("[S2]"))

        let footer = Citations.decorate(answer: "Kayaking [S1], note [S3].", sources: context.sources)
        XCTAssertTrue(footer.contains("Sources: "))
        XCTAssertFalse(footer.contains("February"))
    }

    // MARK: - Transcript coverage

    func testCoverageReportsSessionsAndCharactersTheRankerLeftOut() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try makeRankedHistory(patient)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking")

        // Three sessions have transcripts; the 60-line filler ones are mostly
        // dropped, and February has no passage at all.
        XCTAssertEqual(context.coverage.sessions, 3)
        XCTAssertGreaterThanOrEqual(context.coverage.sessionsWithoutPassages, 1)
        XCTAssertLessThan(context.coverage.includedCharacters, context.coverage.totalCharacters)
        XCTAssertTrue(context.coverage.isPartial)
        let notice = try XCTUnwrap(context.coverage.notice)
        XCTAssertTrue(notice.contains("% of the transcript text"))
    }

    func testCoverageHasNoNoticeWhenEverythingFits() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("Short transcript.", for: patient, session: jan)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")

        XCTAssertEqual(context.coverage.sessions, 1)
        XCTAssertEqual(context.coverage.sessionsWithoutPassages, 0)
        XCTAssertFalse(context.coverage.isPartial)
        XCTAssertNil(context.coverage.notice)
    }

    func testCoveragePercentRoundsDownAndNeverShowsFullWhenPartial() {
        let coverage = TranscriptCoverage(
            sessions: 2, sessionsWithoutPassages: 1, totalCharacters: 1000, includedCharacters: 999
        )
        XCTAssertEqual(coverage.percentIncluded, 99)
        XCTAssertEqual(TranscriptCoverage().percentIncluded, 100)
        XCTAssertNil(TranscriptCoverage().notice)
    }

    // MARK: - Per-session cap

    func testExtrasAreCappedPerSessionWithAMarkerAndTranscriptsSurvive() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Transcript line stays.", for: patient, session: session)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: session.id, text: String(repeating: "n", count: 10_000))
        try store.saveNote("Generated body after a long note.", for: patient, session: session, format: .soap)

        let text = section(store.gatherCitedPatientContext(for: patient, relevantTo: "x").text, tag: "S1")
        XCTAssertTrue(text.contains("Transcript line stays."))
        XCTAssertTrue(text.contains("… [truncated]"))
        XCTAssertTrue(text.contains("[further notes omitted]"))
        XCTAssertFalse(text.contains("Generated body after a long note."))
        XCTAssertLessThan(text.count, Store.patientChatSessionExtrasLimit + 1_000)
    }

    func testCappedKeepsShortBlocksWhole() {
        XCTAssertEqual(Store.capped(["a", "b"], limit: 10), ["a", "b"])
        XCTAssertEqual(Store.capped([], limit: 10), [])
        XCTAssertEqual(Store.capped(["abcdef"], limit: 3), ["abc… [truncated]"])
        XCTAssertEqual(Store.capped(["abc", "def"], limit: 3), ["abc", "[further notes omitted]"])
    }

    // MARK: - Unreadable transcripts

    func testUnreadableTranscriptGetsAMarkerAndIsCounted() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let good = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Readable transcript.", for: patient, session: good)
        let locked = try store.createSession(for: patient, on: date(2026, 1, 5))
        // Sealed with a key this passthrough store doesn't hold: present, but unreadable.
        let url = store.sessionDir(for: patient, session: locked).appendingPathComponent("transcript.txt")
        try FileProtector(key: SymmetricKey(size: .bits256)).write("secret", to: url)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")

        XCTAssertEqual(context.unreadableSessions, 1)
        XCTAssertTrue(section(context.text, tag: "S1").contains("Readable transcript."))
        XCTAssertTrue(section(context.text, tag: "S2").contains(Store.unreadableTranscriptMarker))
        XCTAssertFalse(context.text.contains("secret"))
        XCTAssertEqual(context.sources.count, 2, "the unreadable session is in the context, so it is citable")

        // The single-session read path keeps treating it as "no transcript".
        XCTAssertNil(store.transcript(for: patient, session: locked))
        XCTAssertThrowsError(try store.readTranscript(for: patient, session: locked))
    }

    func testMissingTranscriptIsNotCountedAsUnreadable() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try store.createSession(for: patient, on: date(2026, 2, 1))
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")
        XCTAssertEqual(context.unreadableSessions, 0)
        XCTAssertTrue(context.sources.isEmpty)
        XCTAssertFalse(context.text.contains(Store.unreadableTranscriptMarker))
    }

    // MARK: - Prompt

    func testQuestionAppearsOnceWhenHistoryAlreadyEndsWithIt() {
        let question = "Did she mention the quokka?"
        let history = [
            ChatMessage(role: .user, text: "Earlier question"),
            ChatMessage(role: .assistant, text: "Earlier answer"),
            ChatMessage(role: .user, text: question),
        ]
        let prompt = Prompts.patientChat(context: "CTX", history: history, question: question)
        XCTAssertEqual(occurrences(of: question, in: prompt), 1)
        XCTAssertTrue(prompt.contains("Earlier question"))
        XCTAssertTrue(prompt.contains("Earlier answer"))
    }

    func testQuestionAppearsOnceWithPriorHistoryOnly() {
        let question = "Did she mention the quokka?"
        let history = [
            ChatMessage(role: .user, text: "Earlier question"),
            ChatMessage(role: .assistant, text: "Earlier answer"),
        ]
        let prompt = Prompts.patientChat(context: "CTX", history: history, question: question)
        XCTAssertEqual(occurrences(of: question, in: prompt), 1)
    }

    func testPromptNamesEachKindOfMaterial() {
        let prompt = Prompts.patientChat(context: "CTX", history: [], question: "Q")
        XCTAssertTrue(prompt.contains("transcript"))
        XCTAssertTrue(prompt.contains("Generated progress note"))
        XCTAssertTrue(prompt.contains("Therapist's session notes"))
        XCTAssertTrue(prompt.contains("Therapist's margin comments"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("cite"))
    }
}
