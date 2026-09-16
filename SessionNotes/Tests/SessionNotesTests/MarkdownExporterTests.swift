import XCTest
@testable import SessionNotes

final class MarkdownExporterTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testSessionIncludesSummaryAndTranscriptHeadings() {
        let md = MarkdownExporter.session(
            date: date(2026, 9, 16),
            patientName: "Jane Doe",
            transcript: "[00:00] Therapist: Hello.",
            summary: "Brief check-in."
        )
        XCTAssertTrue(md.contains("# Session Notes — Jane Doe"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("Brief check-in."))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("[00:00] Therapist: Hello."))
    }

    func testSessionOmitsMissingSections() {
        let md = MarkdownExporter.session(date: date(2026, 9, 16), patientName: "Jane Doe", transcript: nil, summary: nil)
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertFalse(md.contains("## Transcript"))
        XCTAssertTrue(md.contains("No transcript or summary recorded"))
    }

    func testPatientHistoryIncludesNotesAndEachSession() {
        let sessions = [
            SessionExport(date: date(2026, 3, 1), transcript: "Newer transcript.", summary: "Newer summary."),
            SessionExport(date: date(2026, 1, 1), transcript: "Older transcript.", summary: ""),
        ]
        let md = MarkdownExporter.patientHistory(patientName: "Jane Doe", notes: "Prefers mornings.", sessions: sessions)
        XCTAssertTrue(md.contains("# Jane Doe — Session History"))
        XCTAssertTrue(md.contains("## Patient Notes"))
        XCTAssertTrue(md.contains("Prefers mornings."))
        XCTAssertTrue(md.contains("Newer transcript."))
        XCTAssertTrue(md.contains("Older transcript."))

        // Caller passes newest-first; the exporter preserves that order.
        let newer = md.range(of: "Newer transcript.")!
        let older = md.range(of: "Older transcript.")!
        XCTAssertLessThan(newer.lowerBound, older.lowerBound)
    }

    func testPatientHistoryWithNoSessions() {
        let md = MarkdownExporter.patientHistory(patientName: "Jane Doe", notes: "", sessions: [])
        XCTAssertTrue(md.contains("No sessions recorded yet."))
        XCTAssertFalse(md.contains("## Patient Notes"))
    }

    func testFileNameStripsPathSeparators() {
        let name = FileSaver.fileName("Jane/Doe", "2026-09-16")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.contains("Jane-Doe"))
        XCTAssertTrue(name.contains("2026-09-16"))
    }
}
