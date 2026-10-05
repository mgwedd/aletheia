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
        let context = PatientContextRetriever.context(for: docs, question: "medication dosage", characterBudget: 40)
        XCTAssertTrue(context.contains("medication"), "the relevant passage should be included")
        XCTAssertFalse(context.contains("kayaking"), "an irrelevant passage should be dropped")
    }

    func testNoQueryTermsFallsBackToWholeHistory() {
        let docs = [
            TranscriptDocument(date: date(2026, 1, 1), text: "Session one content."),
            TranscriptDocument(date: date(2026, 2, 1), text: "Session two content."),
        ]
        // Punctuation-only question yields no terms → whole history.
        let context = PatientContextRetriever.context(for: docs, question: "???", characterBudget: 1)
        XCTAssertTrue(context.contains("Session one content."))
        XCTAssertTrue(context.contains("Session two content."))
    }

    func testKeepsDatedHeadersSoModelCanCite() {
        let docs = [TranscriptDocument(date: date(2026, 1, 1), text: "Discussed anxiety at length.")]
        let context = PatientContextRetriever.context(for: docs, question: "anxiety", characterBudget: 10_000)
        XCTAssertTrue(context.contains("===== Session"), "a dated header should prefix each session's content")
    }
}
