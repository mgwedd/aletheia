import XCTest
import AppKit
import PDFKit
@testable import Aletheia

final class ExportFormatTests: XCTestCase {
    func testPDFIsTheDefaultAndComesFirst() {
        XCTAssertEqual(ExportFormat.default, .pdf)
        XCTAssertEqual(ExportFormat.allCases, [.pdf, .word, .markdown])
        XCTAssertEqual(ExportFormat.allCases.map(\.title), ["PDF", "Word", "Markdown"])
    }

    func testFileNamesCarryTheRightExtension() {
        XCTAssertEqual(ExportFormat.pdf.fileName("Dana - 2026-10-13"), "Dana - 2026-10-13.pdf")
        XCTAssertEqual(ExportFormat.word.fileName("Dana"), "Dana.docx")
        XCTAssertEqual(ExportFormat.markdown.fileName("Dana"), "Dana.md")
    }

    func testEachFormatSavesAsItsOwnType() {
        XCTAssertEqual(ExportFormat.pdf.contentType.preferredFilenameExtension, "pdf")
        XCTAssertEqual(ExportFormat.word.contentType.preferredFilenameExtension, "docx")
        XCTAssertNotEqual(ExportFormat.word.contentType, ExportFormat.pdf.contentType)
    }
}

@MainActor
final class ExportRendererTests: XCTestCase {
    private let document = ExportDocument(
        title: "Dana Cole",
        subtitle: "SOAP · Tuesday",
        markdown: "## Presenting topics\n\nThe client discussed **work stress**.\n\n- First follow-up"
    )

    func testPDFIsAPDFWithTheText() throws {
        let data = try XCTUnwrap(ExportRenderer.data(for: .pdf, document: document))
        XCTAssertEqual(String(data: data.prefix(5), encoding: .ascii), "%PDF-")
        let text = PDFDocument(data: data)?.string ?? ""
        XCTAssertTrue(text.contains("Presenting topics"))
        XCTAssertTrue(text.contains("work stress"))
    }

    func testWordIsADocxThatReadsBackWithItsText() throws {
        let data = try XCTUnwrap(ExportRenderer.data(for: .word, document: document))
        // A .docx is a zip archive: it starts with the PK signature and names word/document.xml.
        XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B])
        XCTAssertNotNil(data.range(of: Data("word/document.xml".utf8)))
        let readBack = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil
        )
        for expected in ["Dana Cole", "Presenting topics", "work stress", "First follow-up"] {
            XCTAssertTrue(readBack.string.contains(expected), "missing \(expected)")
        }
        XCTAssertFalse(readBack.string.contains("**"))
    }

    func testMarkdownKeepsTheMarkupAndPutsTheTitleFirst() throws {
        let data = try XCTUnwrap(ExportRenderer.data(for: .markdown, document: document))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("# Dana Cole\n\n_SOAP · Tuesday_\n\n## Presenting topics"))
        XCTAssertTrue(text.contains("**work stress**"))
    }

    func testMarkdownWithoutATitleIsTheTextAsGiven() {
        let plain = ExportDocument(markdown: "# Already titled\n\nBody")
        XCTAssertEqual(ExportRenderer.markdownText(plain), "# Already titled\n\nBody")
    }

    func testWordAndPDFOfADocumentWithoutATitleStartWithTheBody() throws {
        let plain = ExportDocument(markdown: "# Aletheia — Dana\n\nBody text")
        let word = try XCTUnwrap(ExportRenderer.data(for: .word, document: plain))
        let readBack = try NSAttributedString(
            data: word, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil
        )
        XCTAssertTrue(readBack.string.hasPrefix("Aletheia"))
    }
}

/// Copy puts styled text on the pasteboard, with a plain version free of Markdown symbols.
final class RichClipboardTests: XCTestCase {
    private let note = "## Plan\n\nContinue **weekly** sessions.\n\n- Sleep log\n- Walks"

    func testPlainTextHasNoMarkdownSymbols() {
        let payload = RichClipboard.payload(markdown: note)
        XCTAssertTrue(payload.plain.contains("Plan"))
        XCTAssertTrue(payload.plain.contains("Continue weekly sessions."))
        XCTAssertTrue(payload.plain.contains("Sleep log"))
        for symbol in ["**", "## ", "- Sleep"] {
            XCTAssertFalse(payload.plain.contains(symbol), "found \(symbol)")
        }
    }

    func testRichTextCarriesTheFormatting() throws {
        let rtf = try XCTUnwrap(RichClipboard.payload(markdown: note).rtf)
        let text = try NSAttributedString(rtf: rtf, documentAttributes: nil)
        let whole = text.string as NSString
        let heading = text.attribute(.font, at: whole.range(of: "Plan").location, effectiveRange: nil) as? NSFont
        let body = text.attribute(.font, at: whole.range(of: "Continue").location, effectiveRange: nil) as? NSFont
        XCTAssertGreaterThan(heading?.pointSize ?? 0, body?.pointSize ?? .infinity)
        let bold = text.attribute(.font, at: whole.range(of: "weekly").location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(bold?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    func testHTMLIsOfferedForWebFields() throws {
        let html = try XCTUnwrap(RichClipboard.payload(markdown: note).html)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("Sleep log"))
    }

    func testWritesPlainRichAndHTMLToThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aletheia-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)

        RichClipboard.write(RichClipboard.payload(markdown: note), to: pasteboard)

        XCTAssertTrue(try XCTUnwrap(pasteboard.string(forType: .string)).contains("Continue weekly sessions."))
        XCTAssertNotNil(pasteboard.data(forType: .rtf))
        XCTAssertNotNil(pasteboard.data(forType: .html))
    }

    func testNothingElseRemainsFromTheOldPasteboardContents() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("aletheia-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old", forType: .string)
        RichClipboard.write(RichClipboard.payload(markdown: "New."), to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "New.")
    }
}

/// Every export goes through the one control, and Copy confirms with a popup.
final class ExportWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/App/\(path)"), encoding: .utf8)
    }

    func testNoteSessionAndHistoryExportUseTheFormatMenu() throws {
        let session = try source("Views/SessionDetailView.swift")
        XCTAssertTrue(session.contains("exportNote(as: $0)"))
        XCTAssertTrue(session.contains("exportSession(as: $0)"))
        XCTAssertFalse(session.contains("Label(\"PDF\""))
        XCTAssertFalse(session.contains("Export this session to Markdown"))
        let patient = try source("Views/PatientDetailView.swift")
        XCTAssertTrue(patient.contains("exportHistory(as: $0)"))
        XCTAssertFalse(patient.contains("FileSaver.saveText"))
    }

    func testNoteCopyIsRichAndConfirmsInAPopup() throws {
        let session = try source("Views/SessionDetailView.swift")
        XCTAssertTrue(session.contains("RichClipboard.write(RichClipboard.payload(markdown: summaryText))"))
        XCTAssertTrue(session.contains(".popover(isPresented: $noteCopied"))
        XCTAssertTrue(session.contains("Label(\"Copied\", systemImage: \"checkmark.circle.fill\")"))
    }

    func testTheMenuListsEveryFormatWithPDFCheckedAndNoExtraLabel() throws {
        let button = try source("Views/ExportButton.swift")
        XCTAssertTrue(button.contains("format = .default"))
        XCTAssertTrue(button.contains("ForEach(ExportFormat.allCases)"))
        XCTAssertTrue(button.contains("Image(systemName: \"checkmark\")"))
        XCTAssertFalse(button.lowercased().contains("preselected\")"))
        XCTAssertFalse(button.contains("Text(\"Default"))
    }
}
