import XCTest
@testable import Aletheia

final class SafeMarkdownTests: XCTestCase {
    func testLinkRunsAreRemoved() throws {
        let inputs = [
            "see [x](https://e.com/?q=a)",
            "see <https://e.com/?q=a>",
            "see [x](file:///etc/passwd)",
            "see [x](javascript:alert(1))",
            "see [x](custom-scheme://open?p=1)",
        ]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for input in inputs {
            // Each input really is a link to the plain parser, so the check below is not vacuous.
            let raw = try AttributedString(markdown: input, options: options)
            XCTAssertTrue(raw.runs.contains { $0.link != nil }, input)
            let out = try XCTUnwrap(SafeMarkdown.attributed(from: input), input)
            XCTAssertTrue(out.runs.allSatisfy { $0.link == nil }, input)
        }
    }

    func testLinkTextIsKept() throws {
        let out = try XCTUnwrap(SafeMarkdown.attributed(from: "go to [the **site**](https://e.com) now"))
        XCTAssertEqual(String(out.characters), "go to the site now")
    }

    /// Model Markdown is parsed only through `SafeMarkdown` in the views.
    func testViewsParseMarkdownOnlyThroughTheHelper() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "SafeMarkdown.swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("AttributedString(markdown:"), url.lastPathComponent)
        }
    }
}
