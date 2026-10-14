import XCTest
@testable import Aletheia

final class PatientContextRetrieverTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testEmptyDocumentsReturnEmptyString() {
        XCTAssertEqual(PatientContextRetriever.context(for: [], question: "anything"), "")
        let blank = [TranscriptDocument(date: date(2026, 1, 1), text: "   \n  ")]
        XCTAssertEqual(PatientContextRetriever.context(for: blank, question: "anything"), "")
    }

    func testSmallHistoryReturnsWholeNewestFirst() {
        let docs = [
            TranscriptDocument(date: date(2026, 1, 1), text: "Oldest session about sleep."),
            TranscriptDocument(date: date(2026, 3, 1), text: "Newest session about work."),
        ]
        let context = PatientContextRetriever.context(for: docs, question: "sleep", characterBudget: 10_000)
        XCTAssertTrue(context.contains("Oldest session about sleep."))
        XCTAssertTrue(context.contains("Newest session about work."))
        let newestRange = context.range(of: "Newest session")
        let oldestRange = context.range(of: "Oldest session")
        XCTAssertNotNil(newestRange)
        XCTAssertNotNil(oldestRange)
        XCTAssertLessThan(newestRange!.lowerBound, oldestRange!.lowerBound, "newest session should come first")
    }

    func testLargeHistoryKeepsRelevantPassageAndDropsIrrelevant() {
        let docs = [
            TranscriptDocument(date: date(2026, 1, 1), text: "[00:00] Therapist: We talked about your medication and dosage."),
            TranscriptDocument(date: date(2026, 2, 1), text: "[00:00] Therapist: You described a weekend of kayaking and hiking."),
            TranscriptDocument(date: date(2026, 3, 1), text: "[00:00] Therapist: A general check-in about work."),
        ]
        // Budget below the total, so the retrieval path (not whole-history) runs.
        let context = PatientContextRetriever.context(for: docs, question: "medication dosage", characterBudget: 200)
        XCTAssertTrue(context.contains("medication"), "the relevant passage should be included")
        XCTAssertFalse(context.contains("kayaking"), "an irrelevant passage should be dropped")
    }

    func testNoQueryTermsSendsTheNewestSessionsThatFit() {
        let docs = (1...5).map { TranscriptDocument(date: date(2026, $0, 1), text: String(repeating: "x", count: 400) + " session \($0)") }
        // "???" has no terms. Room for about two sessions, not five.
        let search = SessionSearch.search(docs.map { .init(date: $0.date, tag: "", kind: .transcript, text: $0.text) }, question: "???")
        let selection = PatientContextRetriever.select(transcripts: docs, search: search, characterBudget: 1_000)
        XCTAssertEqual(selection.excerpts.map(\.date), [date(2026, 5, 1), date(2026, 4, 1)])
        XCTAssertFalse(selection.whole, "older sessions were dropped")
        XCTAssertTrue(selection.fullTexts)
        let rendered = selection.excerpts.reduce(0) { $0 + PatientContextRetriever.header($1.date, labels: [:]).count + $1.text.count + 3 }
        XCTAssertLessThanOrEqual(rendered, 1_000)
    }

    func testTermlessQuestionOverAHistoryLargerThanTheBudgetStaysWithinIt() {
        // "What did we talk about last time?" has no searchable words.
        let docs = (1...12).map { TranscriptDocument(date: date(2026, $0, 1), text: String(repeating: "word ", count: 2_000)) }
        let context = PatientContextRetriever.context(for: docs, question: "What did we talk about last time?", characterBudget: 25_000)
        XCTAssertLessThanOrEqual(context.count, 25_000)
        XCTAssertTrue(context.contains("===== Session"))
    }

    func testBestHitIsTrimmedToFitRatherThanKeptWhole() {
        let long = "[00:01] Patient: Dana " + String(repeating: "and so on ", count: 100)
        let docs = [TranscriptDocument(date: date(2026, 1, 1), text: long + "\n[00:02] Patient: filler\n" + String(repeating: "[00:03] Patient: more filler\n", count: 50))]
        let search = SessionSearch.search([.init(date: docs[0].date, tag: "S1", kind: .transcript, text: docs[0].text)], question: "Dana")
        let selection = PatientContextRetriever.select(transcripts: docs, search: search, characterBudget: 200)
        let used = selection.excerpts.reduce(0) { $0 + PatientContextRetriever.header($1.date, labels: [:]).count + $1.text.count + 3 }
        XCTAssertFalse(selection.excerpts.isEmpty)
        XCTAssertLessThanOrEqual(used, 200)
        XCTAssertFalse(selection.whole)
    }

    func testKeepsDatedHeadersSoModelCanCite() {
        let docs = [TranscriptDocument(date: date(2026, 1, 1), text: "Discussed anxiety at length.")]
        let context = PatientContextRetriever.context(for: docs, question: "anxiety", characterBudget: 10_000)
        XCTAssertTrue(context.contains("===== Session"), "a dated header should prefix each session's content")
    }

    func testHitsComeWithTwoLinesOfContextAndGapsAreMarked() {
        let lines = (1...40).map { "[00:\(String(format: "%02d", $0))] Patient: filler line number \($0) about errands" }
        var text = lines
        text[9] = "[00:10] Patient: Then Dana called."
        text[30] = "[00:31] Patient: Dana again."
        let docs = [TranscriptDocument(date: date(2026, 1, 1), text: text.joined(separator: "\n"))]
        let context = PatientContextRetriever.context(for: docs, question: "Dana", characterBudget: 600)
        XCTAssertTrue(context.contains("[00:08]") && context.contains("[00:12]"), "two lines either side")
        XCTAssertFalse(context.contains("[00:07]") || context.contains("[00:13]"))
        XCTAssertTrue(context.contains("\n…\n"), "a gap between windows is marked")
    }

    func testSelectionCountsShownHitsAndMatchesWholeWordsOnly() {
        let filler = (1...40).map { "[00:\(String(format: "%02d", $0))] Patient: the name and the time of the medication" }
        let docs = [TranscriptDocument(date: date(2026, 1, 1), text: filler.joined(separator: "\n"))]
        let search = SessionSearch.search(
            [SessionSearch.Document(date: docs[0].date, tag: "S1", kind: .transcript, text: docs[0].text)], question: "me"
        )
        XCTAssertEqual(search.totalMentions, 0, "'me' must not match name, time or medication")
        let selection = PatientContextRetriever.select(transcripts: docs, search: search, characterBudget: 100)
        XCTAssertFalse(selection.whole, "no search terms: the newest that fit, and the rest is reported as left out")
    }
}
