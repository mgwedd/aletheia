import XCTest
@testable import Aletheia

final class TextSearchTests: XCTestCase {
    func testMatchesIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(TextSearch.matches("The patient felt Anxious", query: "anxious"))
        XCTAssertTrue(TextSearch.matches("resume review", query: "résumé"))
        XCTAssertFalse(TextSearch.matches("nothing relevant here", query: "anxious"))
    }

    func testMatchesRequiresAllTerms() {
        let text = "discussed sleep and work stress"
        XCTAssertTrue(TextSearch.matches(text, query: "sleep stress"))
        XCTAssertFalse(TextSearch.matches(text, query: "sleep vacation"))
    }

    func testEmptyQueryNeverMatches() {
        XCTAssertFalse(TextSearch.matches("anything", query: "   "))
        XCTAssertTrue(TextSearch.queryTerms("  , . ! ").isEmpty)
    }

    func testSnippetCentersOnMatchWithEllipses() {
        let text = String(repeating: "a ", count: 100) + "keyword " + String(repeating: "b ", count: 100)
        let snippet = TextSearch.snippet(from: text, query: "keyword")
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.localizedCaseInsensitiveContains("keyword"))
        XCTAssertTrue(snippet!.hasPrefix("…"))
        XCTAssertTrue(snippet!.hasSuffix("…"))
    }

    func testSnippetNoEllipsisWhenMatchAtBoundaries() {
        let snippet = TextSearch.snippet(from: "keyword in a short line", query: "keyword")
        XCTAssertEqual(snippet, "keyword in a short line")
    }

    func testSnippetSurvivesMultibyteFolding() {
        // "ß" folds to "ss" (length change); the snippet must still be a
        // valid slice of the ORIGINAL string, not crash or misalign.
        let text = "Grüße und Straße vor dem keyword danach"
        let snippet = TextSearch.snippet(from: text, query: "keyword")
        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet!.contains("keyword"))
    }
}
