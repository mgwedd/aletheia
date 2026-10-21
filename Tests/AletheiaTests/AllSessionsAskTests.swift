import XCTest
@testable import Aletheia

/// "Ask About All Sessions": what the question's words count as, how much
/// text the prompt carries, and the chat list's time label.
@MainActor
final class AllSessionsAskTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        SessionSearch.index = SearchIndex()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AllSessionsAskTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// About `lines` × 65 characters of conversation, with `special` at line 100.
    private func longTranscript(_ session: Int, lines: Int = 140, special: String? = nil) -> String {
        var out = (0..<lines).map { i in
            "[\(i * 6 / 60):\(String(format: "%02d", i * 6 % 60))] \(i % 2 == 0 ? "You" : "Call audio"): "
                + "Session \(session) line \(i) about work, sleep and how the week went."
        }
        if let special { out[100] = "[10:00] Call audio: \(special)" }
        return out.joined(separator: "\n")
    }

    // MARK: - Counted terms

    func testQuestionWordsAreNotCounted() {
        XCTAssertEqual(SessionSearch.terms(from: "whats michaels dream").map(\.text), ["michaels", "dream"])
        XCTAssertEqual(SessionSearch.terms(from: "What is Michael's dream?").map(\.text), ["michael", "dream"])
        XCTAssertEqual(SessionSearch.terms(from: "hows the sleep, whos Dana").map(\.text), ["sleep", "dana"])
    }

    func testTheSearchBlockListsNoCountForAQuestionWord() {
        let documents = [SessionSearch.Document(
            date: date(2026, 3, 1), tag: "S1", kind: .transcript,
            text: "[0:10] Call audio: Michaels dream is to sail.")]
        let result = SessionSearch.search(documents, question: "whats michaels dream", characterBudget: 6_000)
        let block = Prompts.searchBlock(result, shown: 1, whole: true, unreadableSessions: 0)
        XCTAssertFalse(block.contains("\"whats\""), block)
        XCTAssertTrue(block.contains("\"michaels\""), block)
        XCTAssertTrue(block.hasPrefix("Search results (1 session searched; \(Prompts.countsNote)):"), block)
    }

    func testTheModelIsToldToUseTheCountsNotRepeatThem() {
        XCTAssertTrue(Prompts.patientSearchRule.contains("do not repeat, list or quote them"))
        XCTAssertTrue(Prompts.patientSearchRule.contains("never open the answer with them"))
        XCTAssertFalse(Prompts.patientSearchRule.contains("Quote the numbers"))
    }

    // MARK: - Prompt budget

    func testNormalAndFocusGatherAtMostTheirTokenBudget() {
        let huge = 400_000
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .normal, totalBudget: huge),
                       PatientChatAnswer.contextTokenBudget(for: .normal) * ContextBudget.charactersPerToken)
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .focus, totalBudget: huge),
                       PatientChatAnswer.contextTokenBudget(for: .focus) * ContextBudget.charactersPerToken)
        XCTAssertLessThan(PatientChatAnswer.contextTokenBudget(for: .normal), PatientChatAnswer.contextTokenBudget(for: .focus))
        // A smaller Mac's own budget still wins.
        XCTAssertEqual(PatientChatAnswer.initialContextBudget(for: .normal, totalBudget: 27_000), 27_000 - 8_000)
    }

    func testAQuestionAboutOneThingGetsPassagesNotWholeTranscripts() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let days: [(Int, String?)] = [(1, nil), (8, "Michaels dream is to sail around Ireland.")]
        for (day, special) in days {
            let session = try store.createSession(for: patient, on: date(2026, 3, day))
            try store.saveTranscript(longTranscript(day, special: special), for: patient, session: session)
        }
        let question = "whats michaels dream"
        let budget = PatientChatAnswer.initialContextBudget(for: .normal, totalBudget: 400_000)
        let whole = store.gatherCitedPatientContext(
            for: patient, relevantTo: "Summarize her progress", characterBudget: budget)
        let focused = store.gatherCitedPatientContext(for: patient, relevantTo: question, characterBudget: budget)

        XCTAssertGreaterThan(whole.text.count, PatientContextRetriever.passageFirstCharacters, "too long to send whole for any question")
        // Both transcripts fit the budget, so a question across them reads them whole…
        XCTAssertTrue(whole.coverage.wholeTranscripts)
        // …but a question about one thing reads what search found.
        XCTAssertFalse(focused.coverage.wholeTranscripts)
        XCTAssertTrue(focused.text.contains("sail around Ireland"))
        XCTAssertFalse(focused.text.contains("Session 1 line 139 "), "no whole transcript")
        XCTAssertLessThan(focused.text.count, whole.text.count)
        XCTAssertLessThanOrEqual(focused.text.count, budget)
    }

    func testShortTranscriptsStillGoInWhole() {
        let documents = [TranscriptDocument(date: date(2026, 3, 1), text: "[0:10] Call audio: Michaels dream is to sail.")]
        let search = SessionSearch.search(
            documents.map { .init(date: $0.date, tag: "S1", kind: .transcript, text: $0.text) },
            question: "whats michaels dream", characterBudget: 6_000)
        let selection = PatientContextRetriever.select(
            transcripts: documents, search: search, characterBudget: 6_000, wantsWholeTranscripts: false)
        XCTAssertTrue(selection.whole)
    }

    func testOnlyBroadQuestionsReadAcrossSessions() {
        XCTAssertTrue(SessionSearch.readsAcrossSessions("Summarize her progress"))
        XCTAssertTrue(SessionSearch.readsAcrossSessions("What themes keep coming up?"))
        XCTAssertTrue(SessionSearch.readsAcrossSessions("How has her sleep changed?"))
        XCTAssertFalse(SessionSearch.readsAcrossSessions("whats michaels dream"))
        XCTAssertFalse(SessionSearch.readsAcrossSessions("When did kayaking come up?"))
    }

    // MARK: - Chat list time

    func testChatListTimeNeverReadsAsAFutureOrZeroDuration() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(ChatThread.activityLabel(for: now, now: now), "Just now")
        XCTAssertEqual(ChatThread.activityLabel(for: now.addingTimeInterval(0.4), now: now), "Just now", "saved a moment after the row was drawn")
        XCTAssertEqual(ChatThread.activityLabel(for: now.addingTimeInterval(-59), now: now), "Just now")
        let twoMinutes = ChatThread.activityLabel(for: now.addingTimeInterval(-120), now: now)
        XCTAssertTrue(twoMinutes.contains("2"), twoMinutes)
        XCTAssertFalse(twoMinutes.contains("0"), twoMinutes)
        XCTAssertFalse(twoMinutes.hasPrefix("in "), twoMinutes)
    }
}
