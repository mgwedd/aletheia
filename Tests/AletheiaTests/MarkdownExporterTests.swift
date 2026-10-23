import XCTest
@testable import Aletheia

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
        XCTAssertTrue(md.hasPrefix("# Jane Doe\n"))
        XCTAssertFalse(md.contains("Aletheia"))
        XCTAssertFalse(md.contains("AI-generated"))
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

    func testExportedFilesCarryNoAppNameOrAIDisclaimer() throws {
        let md = MarkdownExporter.session(date: date(2026, 9, 16), patientName: "Jane Doe", transcript: nil, summary: "Note.")
        XCTAssertFalse(md.contains("Aletheia"))
        XCTAssertFalse(md.contains("AI-generated"))
        XCTAssertFalse(md.contains("Read alongside"))

        let doc = ExportDocument(title: "Jane Doe", subtitle: "SOAP · Tuesday", markdown: "## Plan\n\nRest.")
        for format in ExportFormat.allCases {
            let data = try XCTUnwrap(MainActor.assumeIsolated { ExportRenderer.data(for: format, document: doc) })
            XCTAssertNil(data.range(of: Data("Aletheia".utf8)), "\(format) export names the app")
            XCTAssertNil(data.range(of: Data("AI-generated".utf8)), "\(format) export has the AI disclaimer")
        }
    }

    func testFileNameStripsPathSeparators() {
        let name = FileSaver.fileName("Jane/Doe", "2026-09-16")
        XCTAssertFalse(name.contains("/"))
        XCTAssertTrue(name.contains("Jane-Doe"))
        XCTAssertTrue(name.contains("2026-09-16"))
    }
}
