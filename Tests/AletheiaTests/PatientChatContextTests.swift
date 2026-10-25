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
        XCTAssertFalse(newest.contains("Therapist's session notes:"), "psychotherapy notes stay out of the patient chat")
        XCTAssertFalse(newest.contains("She seemed brighter today."))
        XCTAssertTrue(newest.contains(Prompts.commentsHeading))
        XCTAssertTrue(newest.contains("revisit next week"))
        XCTAssertFalse(newest.contains("January"), "another session's material must not leak under this header")

        let oldest = section(context.text, tag: "S2")
        XCTAssertTrue(oldest.contains("January transcript text."))
        XCTAssertFalse(oldest.contains("January therapist note."))
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
        _ = annotations.addComment(sessionID: session.id, quotedText: "q", body: "Phone check-in, no recording.")

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
        _ = annotations.addComment(sessionID: jan.id, quotedText: "q", body: "January therapist note.")
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
        _ = annotations.addComment(sessionID: jan.id, quotedText: "q", body: "January therapist note.")

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
        _ = annotations.addComment(sessionID: jan.id, quotedText: "q", body: "January therapist note.")

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: Self.tight)

        // Three sessions have transcripts; only March mentions kayaking.
        XCTAssertEqual(context.coverage.transcriptSessions, 3)
        XCTAssertEqual(context.coverage.sessionsWithPassages, 1)
        XCTAssertEqual(context.coverage.passageTags, ["S1"], "the sessions behind the count, by tag")
        XCTAssertEqual(context.coverage.notesSessions, 1)
        XCTAssertEqual(context.coverage.mentions, 1)
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertTrue(context.coverage.layered)
        XCTAssertEqual(
            context.coverage.label,
            "Read: notes and comments from 1 session · matching transcript lines from 1 of 3 sessions (1 match for your words) · only search reached 3 sessions (3 with no summary yet)"
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
        XCTAssertTrue(context.text.contains("Matching passages are in 1 of 3 sessions searched; no transcript is included whole; below are session summaries, the summaries of the parts search points at, and the top 1 matching transcript passage."))
        XCTAssertTrue(section(context.text, tag: "S1").contains("kayaking"))
    }

    func testSearchBlockSaysZeroMatchesAndThePromptCarriesTheRule() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try makeRankedHistory(patient)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "zeppelin", characterBudget: Self.tight)
        XCTAssertTrue(context.text.contains("Search results (3 sessions searched; \(Prompts.countsNote)):\n- \"zeppelin\": 0 matches"))

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
        _ = annotations.addComment(sessionID: session.id, quotedText: "q", body: String(repeating: "n", count: 10_000))
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
        // The earlier exchange goes in as chat turns, without the question.
        let turns = PromptTurn.recent(history, question: question)
        XCTAssertEqual(turns.map(\.text), ["Earlier question", "Earlier answer"])
        XCTAssertEqual(occurrences(of: question, in: PromptTurn.flattened(turns, then: prompt)), 1)
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

    /// Saves a digest for `session` whose sections cover `parts` (start seconds and text).
    private func saveDigest(
        _ patient: Patient, _ session: SessionRecord, transcript: String, summary: String,
        parts: [(start: Int, end: Int, text: String)] = [(0, 540, "part 1")]
    ) throws {
        let digest = SessionDigest(
            model: "m",
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: NoteFreshness.fingerprint(of: transcript),
            sections: parts.map { SessionDigest.Section(start: $0.start, end: $0.end, digest: $0.text) },
            sessionDigest: summary,
            createdAt: Date()
        )
        try store.saveDigest(digest, for: patient, session: session)
    }

    /// No transcript goes in whole once the history doesn't fit: a question with
    /// no words to search for gets the summaries and notes, the openings of the
    /// newest sessions with no summary yet, and says what it left out.
    func testTermlessQuestionOverAHistoryLargerThanTheBudgetReadsSummariesNotWholeTranscripts() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for i in 0..<8 {
            let session = try store.createSession(for: patient, on: date(2026, 1, 1 + i))
            let transcript = filler(lines: 60)   // ~4,500 characters each
            try store.saveTranscript(transcript, for: patient, session: session)
            if i >= 5 { try saveDigest(patient, session, transcript: transcript, summary: "Summary of day \(i + 1).") }
        }

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "What did we talk about last time?", characterBudget: 12_000)

        XCTAssertLessThanOrEqual(context.text.count, 12_000)
        XCTAssertTrue(context.coverage.layered)
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertTrue(section(context.text, tag: "S1").contains("Session digest:\n<digest>\nSummary of day 8."))
        XCTAssertFalse(section(context.text, tag: "S1").contains("weather"), "a session with a summary gets no transcript text")
        // The summaries' leftover room is shared by at most 4 sessions, newest first:
        // S4–S7 get their openings, cut short; the oldest, S8, gets nothing.
        for tag in ["S4", "S5", "S6", "S7"] {
            let block = section(context.text, tag: tag)
            XCTAssertTrue(block.contains(PatientZoom.openingLabel + "\n<transcript>\n[00:00] Patient: We talked"), tag)
            XCTAssertTrue(block.contains(PatientZoom.openingCutMarker), tag)
        }
        XCTAssertFalse(context.text.contains("===== Session [S8]"))
        XCTAssertEqual(context.coverage.sessionsWithPassages, 0)
        XCTAssertEqual(context.coverage.openingSessions, 4)
        XCTAssertEqual(
            context.coverage.label,
            "Read: summaries of 3 sessions · transcript openings of 4 sessions with no summary yet · nothing from 1 session (no words to search for; 1 with no summary yet)"
        )
        XCTAssertTrue(context.text.contains("no transcript is included whole"))
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
        XCTAssertLessThanOrEqual(context.text.count, characters)
        XCTAssertGreaterThan(context.coverage.openingSessions, 0, "no summaries yet: openings fill their room")
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

        // No transcript has the word, so there are no lines to quote: the room kept
        // for summaries goes to the openings of the newest 4 sessions, none of them whole.
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "zeppelin", characterBudget: 12_000)

        XCTAssertLessThanOrEqual(context.text.count, 12_000)
        XCTAssertEqual(context.coverage.sessionsWithPassages, 0)
        XCTAssertFalse(context.coverage.wholeTranscripts)
        XCTAssertEqual(context.coverage.openingSessions, 4)
        XCTAssertEqual(occurrences(of: PatientZoom.openingLabel, in: context.text), 4)
        XCTAssertEqual(occurrences(of: PatientZoom.openingCutMarker, in: context.text), 4, "each opening is cut short")
        XCTAssertEqual(
            context.coverage.label,
            "Read: transcript openings of 4 sessions with no summary yet · no matching transcript lines (0 matches for your words) · only search reached 2 sessions (2 with no summary yet)"
        )
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
        _ = annotations.addComment(sessionID: session.id, quotedText: "q", body: String(repeating: "n", count: 10_000))

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
        // On this budget the newest 4 keep their own summary (`individualSummaryLimit`); older ones merge by month.
        XCTAssertEqual(context.coverage.monthMergedSessions, 5)
        XCTAssertEqual(context.coverage.digestTags, Set((1...9).map { "S\($0)" }))
        XCTAssertTrue(section(context.text, tag: "S1").contains("Session digest:\n<digest>\nDigest summary for session 9"))
        XCTAssertTrue(context.text.contains("===== Earlier Sessions: December 2025 [S5, S6] ====="))
        XCTAssertTrue(context.text.contains("===== Earlier Sessions: November 2025 [S7] ====="))
        XCTAssertTrue(context.text.contains("===== Earlier Sessions: October 2025 [S8, S9] ====="))
        // The kayaking line is in S1's first part, so that part's summary is shown too.
        XCTAssertTrue(section(context.text, tag: "S1").contains("Summary of the part search points at"))
        XCTAssertEqual(Set(context.sources.map(\.tag)), Set((1...9).map { "S\($0)" }))

        var coverageWithEffort = context.coverage
        coverageWithEffort.effort = .normal
        let label = try XCTUnwrap(coverageWithEffort.label)
        XCTAssertTrue(label.contains("summaries of 9 sessions (5 merged by month)"), label)
        XCTAssertTrue(label.hasSuffix("· Normal"), label)
    }

    func testPatientBackgroundOmittedWhenIncludeBackgroundIsFalse() throws {
        var patient = try store.createPatient(name: "Jane Doe")
        patient.clinicalHistory = "Anxiety disorder"
        patient.notes = "Client prefers afternoon"
        let session = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("March transcript.", for: patient, session: session)

        let withBg = store.gatherCitedPatientContext(for: patient, relevantTo: "anxiety", includeBackground: true)
        XCTAssertTrue(withBg.text.contains("Anxiety disorder"))
        XCTAssertTrue(withBg.text.contains("Client prefers afternoon"))

        let withoutBg = store.gatherCitedPatientContext(for: patient, relevantTo: "anxiety", includeBackground: false)
        XCTAssertFalse(withoutBg.text.contains("Anxiety disorder"))
        XCTAssertFalse(withoutBg.text.contains("Client prefers afternoon"))
    }

    // MARK: - Tool scope tags

    /// Every tag the context cites names the same session in the tool scope, so a
    /// tool result tagged [S2] and the context's [S2] are one session.
    private func assertToolTagsMatch(
        _ context: PatientContext, _ patient: Patient, file: StaticString = #filePath, line: UInt = #line
    ) {
        let scope = store.localToolScope(for: patient)
        XCTAssertFalse(context.sources.isEmpty, file: file, line: line)
        for source in context.sources {
            XCTAssertEqual(
                scope.sessions.first { $0.tag == source.tag }?.folderName, source.folderName,
                "tag \(source.tag)", file: file, line: line)
        }
    }

    func testToolTagsMatchContextTagsWhenANewerTranscriptIsUnreadable() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let good = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("Readable transcript about the garden.", for: patient, session: good)
        let locked = try store.createSession(for: patient, on: date(2026, 3, 5))
        let url = store.sessionDir(for: patient, session: locked).appendingPathComponent("transcript.txt")
        try FileProtector(key: SymmetricKey(size: .bits256)).write("secret", to: url)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "garden")
        XCTAssertEqual(context.sources.map(\.folderName), [locked.folderName, good.folderName])
        assertToolTagsMatch(context, patient)
    }

    func testToolTagsMatchContextTagsWhenTheBudgetDropsANotesOnlySession() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let newest = try store.createSession(for: patient, on: date(2026, 3, 20))
        try store.saveNote(String(repeating: "Long generated note. ", count: 200), for: patient, session: newest, format: .soap)
        let notesOnly = try store.createSession(for: patient, on: date(2026, 3, 10))
        try store.saveNote("Short phone check-in.", for: patient, session: notesOnly, format: .soap)
        let recorded = try store.createSession(for: patient, on: date(2026, 3, 1))
        try store.saveTranscript("[00:01] Patient: The garden is coming along.", for: patient, session: recorded)

        // The newest session's note uses up the room for notes, so the next one's is left out entirely.
        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "garden", characterBudget: 2_000)
        XCTAssertFalse(context.sources.contains { $0.folderName == notesOnly.folderName })
        XCTAssertTrue(context.sources.contains { $0.folderName == recorded.folderName })
        assertToolTagsMatch(context, patient)
    }

    // MARK: - Zoom levels

    /// The parts search points at come with their summaries; the summaries of
    /// parts nothing points at, and the transcripts themselves, stay out.
    func testThePartSearchPointsAtIsSummarizedAndListedToOpen() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for i in 0..<4 {
            let session = try store.createSession(for: patient, on: date(2026, 2, 1 + i))
            try store.saveTranscript(filler(lines: 60), for: patient, session: session)
        }
        let target = try store.createSession(for: patient, on: date(2026, 3, 1))
        var lines = (0..<40).map { "[\(String(format: "%02d", $0)):00] Patient: We talked about the weather and errands today." }
        lines[25] = "[25:00] Patient: The kayaking trip with my brother went badly."
        let transcript = lines.joined(separator: "\n")
        try store.saveTranscript(transcript, for: patient, session: target)
        try saveDigest(patient, target, transcript: transcript, summary: "Whole-session summary.", parts: [
            (0, 590, "Opening small talk about errands."),
            (600, 1190, "Work stress and sleep."),
            (1200, 1740, "A trip with her brother that went badly."),
            (1800, 2340, "Plans for the week."),
        ])

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "kayaking", characterBudget: 9_000)

        XCTAssertTrue(context.coverage.layered)
        let newest = section(context.text, tag: "S1")
        XCTAssertTrue(newest.contains("Session digest:\n<digest>\nWhole-session summary."))
        XCTAssertTrue(newest.contains("Summary of the part search points at [20:00–29:00] (1 matching transcript line):\n<digest>\nA trip with her brother that went badly."), newest)
        XCTAssertFalse(context.text.contains("Opening small talk about errands."), "nothing points at that part")
        XCTAssertTrue(context.text.contains(PatientZoom.areasHeader))
        XCTAssertTrue(context.text.contains("(read_section session S1, start 20:00, end 29:00)"))
        XCTAssertLessThanOrEqual(occurrences(of: "weather and errands", in: context.text), 4, "only the lines around the hit")
        XCTAssertEqual(context.coverage.areas, 1)
        XCTAssertEqual(context.coverage.summarySections, 1)
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).contains("1 summary of the parts search points at"))
        XCTAssertTrue(try XCTUnwrap(context.coverage.label).contains("only search reached 4 sessions (4 with no summary yet)"))
    }

    /// A word only the AI summary of a part has (the transcript says it another
    /// way) still points the question there.
    func testAWordInAPartsSummaryPointsAtThatPart() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for i in 0..<4 {
            let session = try store.createSession(for: patient, on: date(2026, 2, 1 + i))
            try store.saveTranscript(filler(lines: 60), for: patient, session: session)
        }
        let target = try store.createSession(for: patient, on: date(2026, 3, 1))
        let transcript = filler(lines: 60)
        try store.saveTranscript(transcript, for: patient, session: target)
        try saveDigest(patient, target, transcript: transcript, summary: "Whole-session summary.", parts: [
            (0, 30, "Opening small talk."),
            (31, 59, "She describes insomnia most nights."),
        ])

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "insomnia", characterBudget: 9_000)

        XCTAssertTrue(context.text.contains("its summary has 1 of your words"))
        XCTAssertTrue(context.text.contains("She describes insomnia most nights."))
        XCTAssertFalse(context.text.contains("Opening small talk."))
    }

    // MARK: - Openings of sessions with no summary yet

    /// A transcript whose first and last lines name its day, so a test can tell
    /// its opening from the rest.
    private func dayTranscript(_ day: Int, lines: Int = 60) -> String {
        (0..<lines).map { i -> String in
            let text = i == 0
                ? "Day \(day) begins."
                : i == lines - 1 ? "Day \(day) ends." : "Day \(day), line \(i), about the week and errands."
            return "[\(String(format: "%02d", i)):00] Patient: \(text)"
        }.joined(separator: "\n")
    }

    /// A question with no search words over a history too long to send whole,
    /// where some sessions have no summary yet: their openings fill the room
    /// kept for summaries, within the budget, and the coverage line says so.
    func testTermlessQuestionReadsTheOpeningsOfSessionsWithNoSummaryYet() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for day in 1...6 {
            let session = try store.createSession(for: patient, on: date(2026, 1, day))
            let transcript = dayTranscript(day)
            try store.saveTranscript(transcript, for: patient, session: session)
            // S1, S3 and S5 (days 6, 4 and 2) have summaries.
            if day % 2 == 0 { try saveDigest(patient, session, transcript: transcript, summary: "Summary of day \(day).") }
        }

        let context = store.gatherCitedPatientContext(
            for: patient, relevantTo: "What did we talk about last time?", characterBudget: 12_000)

        XCTAssertLessThanOrEqual(context.text.count, 12_000)
        XCTAssertTrue(context.coverage.layered)
        for (tag, day) in [("S2", 5), ("S4", 3), ("S6", 1)] {
            let block = section(context.text, tag: tag)
            XCTAssertTrue(block.contains(PatientZoom.openingLabel + "\n<transcript>\n[00:00] Patient: Day \(day) begins."), tag)
            XCTAssertTrue(block.contains(PatientZoom.openingCutMarker), tag)
            XCTAssertFalse(block.contains("Day \(day) ends."), "\(tag): only the opening, never the whole transcript")
        }
        for (tag, day) in [("S1", 6), ("S3", 4), ("S5", 2)] {
            let block = section(context.text, tag: tag)
            XCTAssertTrue(block.contains("Session digest:\n<digest>\nSummary of day \(day)."), tag)
            XCTAssertFalse(block.contains(PatientZoom.openingLabel), "\(tag) has a summary")
            XCTAssertFalse(block.contains("Day \(day) begins."), tag)
        }
        // Newest first, in the context's session order.
        let newer = try XCTUnwrap(context.text.range(of: "Day 5 begins."))
        let older = try XCTUnwrap(context.text.range(of: "Day 1 begins."))
        XCTAssertLessThan(newer.lowerBound, older.lowerBound)
        XCTAssertTrue(context.text.contains("the start of the transcripts of 3 sessions with no summary yet"))

        XCTAssertEqual(context.coverage.openingSessions, 3)
        XCTAssertEqual(context.coverage.searchOnlySessions, 0, "a session whose opening was read is not one only search reached")
        XCTAssertEqual(context.coverage.sessionsWithPassages, 0)
        XCTAssertEqual(
            context.coverage.label,
            "Read: summaries of 3 sessions · transcript openings of 3 sessions with no summary yet"
        )
        XCTAssertEqual(Set(context.sources.map(\.tag)), Set((1...6).map { "S\($0)" }))
        assertToolTagsMatch(context, patient)
    }

    /// With every session summarized there is nothing to fill in.
    func testEverySessionWithASummaryAddsNoOpenings() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for day in 1...6 {
            let session = try store.createSession(for: patient, on: date(2026, 1, day))
            let transcript = dayTranscript(day)
            try store.saveTranscript(transcript, for: patient, session: session)
            try saveDigest(patient, session, transcript: transcript, summary: "Summary of day \(day).")
        }

        let context = store.gatherCitedPatientContext(
            for: patient, relevantTo: "What did we talk about last time?", characterBudget: 12_000)

        XCTAssertTrue(context.coverage.layered)
        XCTAssertFalse(context.text.contains(PatientZoom.openingLabel))
        XCTAssertFalse(context.text.contains("begins."))
        XCTAssertEqual(context.coverage.openingSessions, 0)
        let label = try XCTUnwrap(context.coverage.label)
        XCTAssertTrue(label.hasPrefix("Read: summaries of 6 sessions"), label)
        XCTAssertFalse(label.contains("no summary yet"), label)
    }

    /// When the transcripts fit whole, they go in whole: no openings.
    func testAHistoryThatFitsWholeAddsNoOpenings() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        for day in 1...2 {
            let session = try store.createSession(for: patient, on: date(2026, 1, day))
            try store.saveTranscript(dayTranscript(day, lines: 5), for: patient, session: session)
        }

        let context = store.gatherCitedPatientContext(
            for: patient, relevantTo: "What did we talk about last time?", characterBudget: 12_000)

        XCTAssertTrue(context.coverage.wholeTranscripts)
        XCTAssertFalse(context.text.contains(PatientZoom.openingLabel))
        XCTAssertTrue(context.text.contains("Day 1 ends."))
        XCTAssertEqual(context.coverage.openingSessions, 0)
    }

    // MARK: - Scale

    /// 100 sessions of about an hour each (~60,000 characters, ~6M in all): the
    /// prompt a question builds still fits a 32K window, for a question that
    /// matches one line and for one with no search words at all.
    func testHundredHourLongSessionsBuildAPromptThatFitsTheWindow() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let calendar = Calendar(identifier: .gregorian)
        for s in 0..<100 {
            let day = calendar.date(byAdding: .day, value: 7 * s, to: date(2024, 1, 1))!
            let session = try store.createSession(for: patient, on: day)
            var lines = (0..<900).map { i in
                "[\(i * 4 / 60):\(String(format: "%02d", i * 4 % 60))] \(i % 2 == 0 ? "You" : "Call audio"): "
                    + "Session \(s) line \(i) about work, sleep and how the week went."
            }
            if s == 17 { lines[450] = "[30:00] Call audio: A weekend of kayaking helped more than anything." }
            try store.saveTranscript(lines.joined(separator: "\n"), for: patient, session: session)
        }

        var service = AssistantService(assistant: NoopAssistant(), model: "m")
        service.budget = ContextBudget(tokens: 32_768)
        for question in ["When did kayaking come up?", "How has she been doing?"] {
            let budget = service.patientContextCharacters(history: [], question: question)
            let context = store.gatherCitedPatientContext(for: patient, relevantTo: question, characterBudget: budget)
            let system = Prompts.chatSystemPrompt(service.systemPrompt, question: question)
            let prompt = Prompts.patientChat(context: context.text, history: [], question: question)
            XCTAssertLessThanOrEqual(context.text.count, budget, question)
            XCTAssertTrue(service.budget.fits(promptCharacters: system.count + prompt.count), question)
            XCTAssertFalse(context.coverage.wholeTranscripts, question)
            XCTAssertEqual(context.coverage.transcriptSessions, 100, question)
            assertToolTagsMatch(context, patient)
        }
        // No summaries yet and no lines to quote: the newest sessions' openings
        // fill the summaries' room, at least 4 sharing it, never one whole.
        let termless = "How has she been doing?"
        let termlessBudget = service.patientContextCharacters(history: [], question: termless)
        let openings = store.gatherCitedPatientContext(for: patient, relevantTo: termless, characterBudget: termlessBudget)
        XCTAssertLessThanOrEqual(openings.text.count, termlessBudget)
        XCTAssertGreaterThanOrEqual(openings.coverage.openingSessions, 4)
        XCTAssertTrue(section(openings.text, tag: "S1").contains(PatientZoom.openingLabel + "\n<transcript>\n[0:00] Y: Session 99 line 0 "))
        XCTAssertFalse(openings.text.contains("Session 99 line 899 "), "never a whole transcript")
        XCTAssertTrue(try XCTUnwrap(openings.coverage.label).contains("with no summary yet"))
        let kayaking = store.gatherCitedPatientContext(
            for: patient, relevantTo: "When did kayaking come up?",
            characterBudget: service.patientContextCharacters(history: [], question: "When did kayaking come up?"))
        XCTAssertTrue(kayaking.text.contains("kayaking"))
        assertToolTagsMatch(kayaking, patient)
    }
}

private final class NoopAssistant: Assistant, @unchecked Sendable {
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { "" }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}
