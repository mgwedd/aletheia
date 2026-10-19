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
        SessionSearch.index = SearchIndex()   // earlier tests may have left a locked file index behind
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PatientChatContextTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// A context budget the ranked history below overflows, so the search path runs.
    private static let tight = 6_000

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

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: Self.tight)

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

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: Self.tight)

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

    func testCoverageLabelComesFromWhatWasSent() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let (jan, _, _) = try makeRankedHistory(patient)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: jan.id, text: "January therapist note.")

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: Self.tight)

        // Three sessions have transcripts; only March mentions kayaking.
        XCTAssertEqual(context.coverage.transcriptSessions, 3)
        XCTAssertEqual(context.coverage.sessionsWithPassages, 1)
        XCTAssertEqual(context.coverage.notesSessions, 1)
        XCTAssertEqual(context.coverage.mentions, 1)
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertEqual(
            context.coverage.label,
            "Read: notes and comments from 1 session · transcript passages from 1 of 3 sessions (1 match for your words)"
        )
    }

    func testCoverageLabelWhenEverythingFits() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("Short transcript.", for: patient, session: jan)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")

        XCTAssertEqual(context.coverage.label, "Read: full transcripts of 1 session")
        XCTAssertNil(TranscriptCoverage().label)
    }

    func testUnreadableSessionIsNotCountedAsRead() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let good = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Dana came up today.", for: patient, session: good)
        let locked = try store.createSession(for: patient, on: date(2026, 1, 5))
        let url = store.sessionDir(for: patient, session: locked).appendingPathComponent("transcript.txt")
        try FileProtector(key: SymmetricKey(size: .bits256)).write("Dana secret", to: url)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "Dana")

        XCTAssertEqual(context.coverage.transcriptSessions, 1)
        XCTAssertEqual(context.coverage.sessionsWithPassages, 1)
        XCTAssertEqual(context.coverage.unreadableSessions, 1)
        XCTAssertEqual(context.coverage.mentions, 1, "the unreadable transcript is not searched")
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).hasSuffix("1 session could not be read, so answers may be incomplete"))
        XCTAssertTrue(context.text.contains("1 session transcript could not be read and was not searched."))
    }

    // MARK: - Search block and the not-discussed rule

    func testSearchBlockStatesExactCounts() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try makeRankedHistory(patient)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: Self.tight)

        XCTAssertTrue(context.text.contains("- \"kayaking\": 1 mention"))
        XCTAssertTrue(context.text.contains("Matching passages are in 1 of 3 sessions searched; showing the top 1 transcript passage."))
        XCTAssertTrue(section(context.text, tag: "S1").contains("kayaking"))
    }

    func testSearchBlockSaysZeroMatchesAndThePromptCarriesTheRule() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try makeRankedHistory(patient)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "zeppelin", characterBudget: Self.tight)
        XCTAssertTrue(context.text.contains("Search results (3 sessions searched):\n- \"zeppelin\": 0 matches"))

        let prompt = Prompts.patientChat(context: context.text, history: [], question: "zeppelin?")
        XCTAssertTrue(prompt.contains("- \"zeppelin\": 0 matches"))
        XCTAssertTrue(prompt.contains("no match found in the recorded sessions"))
        XCTAssertFalse(prompt.contains("say you don't see that in the recorded sessions"))
    }

    func testSearchBlockNamesDateRangeAndVariants() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let old = try store.createSession(for: patient, on: date(2020, 1, 5))
        try store.saveTranscript("Micheal called.", for: patient, session: old)
        let recent = try store.createSession(for: patient, on: Date().addingTimeInterval(-86_400 * 3))
        try store.saveTranscript("Michael called twice. Michael again.", for: patient, session: recent)

        let all = store.gatherCitedPatientContext(for: patient, relevantTo: "Michael")
        XCTAssertTrue(all.text.contains("- \"michael\": 2 mentions; 1 similar spelling (not exact: micheal)"))
        XCTAssertTrue(all.text.contains("Matching passages are in 2 of 2 sessions searched"))

        let recentOnly = store.gatherCitedPatientContext(for: patient, relevantTo: "Michael in the past 6 months")
        XCTAssertTrue(recentOnly.text.contains("- \"michael\": 2 mentions"))
        XCTAssertTrue(recentOnly.text.contains("Matching passages are in 1 of 1 session searched"))
        XCTAssertTrue(recentOnly.text.contains("were searched."))
        XCTAssertEqual(recentOnly.coverage.transcriptSessions, 1)
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

    // MARK: - Sizing from the per-Mac budget

    private func makeLongHistory(_ patient: Patient, sessions: Int, lines: Int) throws {
        for i in 0..<sessions {
            let session = try store.createSession(for: patient, on: date(2026, 1 + i / 20, 1 + i % 20))
            try store.saveTranscript(filler(lines: lines), for: patient, session: session)
        }
    }

    func testTermlessQuestionOverAHistoryLargerThanTheBudgetFitsAndSaysWhatItRead() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        try makeLongHistory(patient, sessions: 8, lines: 60)   // ~4,500 characters each

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "What did we talk about last time?", characterBudget: 12_000)

        XCTAssertLessThanOrEqual(context.text.count, 12_000)
        let read = context.coverage.sessionsWithPassages
        XCTAssertTrue((1..<8).contains(read), "some, not all, of the sessions fit")
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertEqual(context.coverage.label, "Read: full transcripts of the newest \(read) of 8 sessions")
        XCTAssertTrue(context.text.contains("only the full transcripts of the newest \(read) of 8 sessions are included below"))
        XCTAssertTrue(section(context.text, tag: "S1").contains("weather"), "the newest session is the one kept")
    }

    func testWholeContextFitsAnEightGBMacWithManyNotes() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        for i in 0..<30 {
            let session = try store.createSession(for: patient, on: date(2026, 1 + i / 20, 1 + i % 20))
            try store.saveTranscript(filler(lines: 150), for: patient, session: session)
            annotations.saveNote(sessionID: session.id, text: String(repeating: "note ", count: 700))   // 3,500 characters
            try store.saveNote(String(repeating: "generated ", count: 300), for: patient, session: session, format: .soap)
        }
        let budget = ContextBudget(tokens: 16_384)   // an 8 GB Mac
        let service = AssistantService(assistant: NoopAssistant(), model: "m", budget: budget)
        let question = "What did we talk about last time?"
        let characters = service.patientContextCharacters(history: [], question: question)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: question, characterBudget: characters)

        let system = Prompts.chatSystemPrompt(service.systemPrompt, question: question)
        let prompt = Prompts.patientChat(context: context.text, history: [], question: question)
        XCTAssertTrue(budget.fits(promptCharacters: system.count + prompt.count), "never over budget through patient chat")
        XCTAssertGreaterThan(context.coverage.notesCutSessions, 0)
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).contains("cut short or left out for"))
        XCTAssertFalse(context.coverage.wholeTranscripts)
    }

    func testNoRoomLeftForSessionsIsReportedNotSent() {
        let service = AssistantService(assistant: NoopAssistant(), model: "m", budget: ContextBudget(tokens: 16_384))
        let huge = [ChatMessage(role: .user, text: String(repeating: "word ", count: 12_000))]
        XCTAssertEqual(service.patientContextCharacters(history: huge, question: "Q?"), 0)
        XCTAssertFalse(PatientContextBudgetError().localizedDescription.contains("session is longer"))
    }

    func testNotesOnlyMatchWithDroppedSessionsSaysKOfM() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        try makeLongHistory(patient, sessions: 6, lines: 60)

        // A word only a note has: transcript terms find nothing, so the newest sessions that fit go in.
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "zeppelin", characterBudget: 12_000)

        let read = context.coverage.sessionsWithPassages
        XCTAssertLessThan(read, 6)
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).contains("full transcripts of the newest \(read) of 6 sessions"))
        XCTAssertFalse(context.text.contains("the full transcripts are included below"))
    }

    func testTranscriptBudgetIsTrimmedForTheBestHitInsteadOfKeptWhole() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("[00:01] Patient: kayaking " + String(repeating: "paddle ", count: 400), for: patient, session: session)
        let other = try store.createSession(for: patient, on: date(2026, 3, 6))
        try store.saveTranscript(filler(lines: 60), for: patient, session: other)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: 1_500)

        XCTAssertLessThanOrEqual(context.text.count, 1_500)
        XCTAssertTrue(context.text.contains("kayaking"))
    }

    func testExtrasCutIsSaidInTheLabel() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("Short.", for: patient, session: session)
        let annotations = try XCTUnwrap(CommentStore(root: tempRoot))
        annotations.saveNote(sessionID: session.id, text: String(repeating: "n", count: 10_000))

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "x", characterBudget: 50_000)

        XCTAssertEqual(context.coverage.notesCutSessions, 1)
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).contains("notes and comments from 1 session (cut short or left out for 1 session)"))
    }

    func testCoverageLabelWithSimilarSpellingsKeepsThemApart() {
        let coverage = TranscriptCoverage(
            transcriptSessions: 2, sessionsWithPassages: 2, mentions: 3, similarMentions: 2, searched: true, wholeTranscripts: true
        )
        XCTAssertEqual(coverage.label, "Read: full transcripts of 2 sessions (3 matches for your words, 2 more with similar spelling)")
    }

    func testStoredDigestsAndMonthMergedHistoryAreIncludedAndCitable() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let sessionDates: [(Int, Int, Int)] = [
            (2025, 10, 4), (2025, 10, 18), (2025, 11, 8),
            (2025, 12, 1), (2025, 12, 15), (2026, 1, 10),
            (2026, 2, 7), (2026, 3, 1), (2026, 3, 15),
        ]
        for (idx, (y, m, d)) in sessionDates.enumerated() {
            let s = try store.createSession(for: patient, on: date(y, m, d))
            let transcript = filler(lines: 60) + (idx == 8 ? "\n[15:00] Patient: kayaking trip helped." : "")
            try store.saveTranscript(transcript, for: patient, session: s)
            let digest = SessionDigest(
                model: "m",
                promptVersion: Prompts.digestVersion,
                transcriptFingerprint: NoteFreshness.fingerprint(of: transcript),
                sections: [.init(start: 0, end: 540, digest: "part 1")],
                sessionDigest: "Digest summary for session \(idx + 1) on \(y)-\(m)-\(d).",
                createdAt: Date()
            )
            try store.saveDigest(digest, for: patient, session: s)
        }

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: 12_000)

        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertEqual(context.coverage.digestSessions, 9)
        XCTAssertEqual(context.coverage.monthMergedSessions, 3)
        // Recent 6 sessions (S1..S6) get individual digests; older 3 (S7..S9 in Oct/Nov 2025) are merged by month.
        XCTAssertTrue(section(context.text, tag: "S1").contains("Session digest:\nDigest summary for session 9"))
        XCTAssertTrue(context.text.contains("===== Earlier Sessions: November 2025 [S7] ====="))
        XCTAssertTrue(context.text.contains("===== Earlier Sessions: October 2025 [S8, S9] ====="))
        XCTAssertEqual(Set(context.sources.map(\.tag)), Set((1...9).map { "S\($0)" }))

        var coverageWithEffort = context.coverage
        coverageWithEffort.effort = .normal
        let label = try XCTUnwrap(coverageWithEffort.label)
        XCTAssertTrue(label.contains("digests of 9 sessions (3 merged by month)"), label)
        XCTAssertTrue(label.hasSuffix("· Normal"), label)
    }
}

private final class NoopAssistant: Assistant, @unchecked Sendable {
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { "" }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}
