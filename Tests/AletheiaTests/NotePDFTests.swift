import XCTest
import PDFKit
@testable import Aletheia

@MainActor
final class NotePDFTests: XCTestCase {
    private let sample = """
    ## Presenting topics

    The client discussed **work stress** and a recent *staycation*.

    - First follow-up
    - Second follow-up

    1. Revisit the project
    2. Check in on sleep

    > "I think I've got some solutions."
    """

    private func document(_ markdown: String) throws -> PDFDocument {
        let data = try XCTUnwrap(NotePDF.render(markdown: markdown, title: "Dana Cole", subtitle: "SOAP · Tuesday"))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    func testRendersAReadablePDF() throws {
        let data = try XCTUnwrap(NotePDF.render(markdown: sample, title: "Dana Cole", subtitle: "SOAP · Tuesday"))
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        let text = try document(sample).string ?? ""
        for expected in ["Dana Cole", "SOAP", "Presenting topics", "work stress", "First follow-up", "Check in on sleep", "solutions"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)")
        }
    }

    func testMarkdownMarkersAreNotPrintedLiterally() throws {
        let text = try document(sample).string ?? ""
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("## "))
    }

    func testALongNoteRunsOverSeveralPages() throws {
        let long = (1...120).map { "Paragraph \($0): " + String(repeating: "words ", count: 40) }.joined(separator: "\n\n")
        XCTAssertGreaterThan(try document(long).pageCount, 2)
        XCTAssertEqual(try document("Short.").pageCount, 1)
    }

    func testPagesAreUSLetter() throws {
        let page = try XCTUnwrap(try document(sample).page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, NotePDF.paper.width, accuracy: 1)
        XCTAssertEqual(bounds.height, NotePDF.paper.height, accuracy: 1)
    }

    func testHeadingsAreLargerThanBodyText() {
        let text = NotePDF.attributedText(markdown: "## Heading\n\nBody text here.", title: "T", subtitle: "S")
        let full = text.string as NSString
        let headingFont = text.attribute(.font, at: full.range(of: "Heading").location, effectiveRange: nil) as? NSFont
        let bodyFont = text.attribute(.font, at: full.range(of: "Body").location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(headingFont?.pointSize ?? 0, bodyFont?.pointSize ?? .infinity)
    }

    func testListsGetMarkers() {
        let text = NotePDF.attributedText(markdown: "- one\n- two\n\n1. first\n2. second", title: "T", subtitle: "S").string
        XCTAssertTrue(text.contains("•\tone"))
        XCTAssertTrue(text.contains("2.\tsecond"))
    }
}

    func testAnEmptyTitleAndSubtitleLeaveOutTheHeader() {
        let text = NotePDF.attributedText(markdown: "Body.", title: "", subtitle: "").string
        XCTAssertEqual(text, "Body.\n")
    }
}
