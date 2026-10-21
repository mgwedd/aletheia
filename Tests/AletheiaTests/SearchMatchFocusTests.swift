import XCTest
@testable import Aletheia

/// Opening a transcript or note hit at its match: which text to flash, matched
/// the way the search matches. Synthetic text.
final class SearchMatchFocusTests: XCTestCase {
    private func flashed(_ query: String, passage: Int, in text: String) -> String? {
        guard let range = SearchMatchFocus(query: query, passage: passage).transcriptRange(in: text) else { return nil }
        return (text as NSString).substring(with: range)
    }

    private func location(_ query: String, passage: Int, in text: String) -> Int? {
        SearchMatchFocus(query: query, passage: passage).transcriptRange(in: text)?.location
    }

    // MARK: Transcript

    func testFlashesTheMatchInTheHitsLineNotAnEarlierOne() {
        let text = "[00:01] You: The garden was quiet.\n[00:05] Client: I miss the garden.\n[00:09] You: Tell me more."
        let second = (text as NSString).range(of: "garden", options: .backwards)
        XCTAssertEqual(SearchMatchFocus(query: "garden", passage: 1).transcriptRange(in: text), second)
        XCTAssertEqual(location("garden", passage: 0, in: text), (text as NSString).range(of: "garden").location)
    }

    func testMatchesLikeTheSearchIgnoringCaseAndDiacritics() {
        let text = "[00:01] You: Hello.\n[00:03] Client: We met at the CAFÉ again."
        XCTAssertEqual(flashed("cafe", passage: 1, in: text), "CAFÉ")
        XCTAssertEqual(flashed("Café", passage: 1, in: text), "CAFÉ")
    }

    func testMatchesInflectedAndPartlyTypedWords() {
        let text = "[00:01] You: Hello.\n[00:03] Client: I worried all week about therapy."
        XCTAssertEqual(flashed("worries", passage: 1, in: text), "worried")
        XCTAssertEqual(flashed("thera", passage: 1, in: text), "therapy")
    }

    func testRangeIsInUTF16AfterWideCharacters() {
        let text = "[00:01] You: 😀😀 hello\n[00:03] Client: the garden 🌱 grows"
        XCTAssertEqual(flashed("garden", passage: 1, in: text), "garden")
    }

    func testFallsBackToTheFirstMatchWhenTheLineNoLongerHasOne() {
        let text = "[00:01] You: The garden.\n[00:05] Client: Nothing here."
        XCTAssertEqual(location("garden", passage: 1, in: text), (text as NSString).range(of: "garden").location)
        XCTAssertEqual(location("garden", passage: 9, in: text), (text as NSString).range(of: "garden").location)
    }

    func testNothingToFlashWhenNothingMatches() {
        XCTAssertNil(SearchMatchFocus(query: "garden", passage: 0).transcriptRange(in: "[00:01] You: Hello."))
        XCTAssertNil(SearchMatchFocus(query: "garden", passage: 0).transcriptRange(in: ""))
    }

    func testLineRangeSplitsAtNewlines() {
        let text = "one\ntwo\n\nfour"
        XCTAssertEqual(SearchMatchFocus.lineRange(1, in: text).map { String(text[$0]) }, "two")
        XCTAssertEqual(SearchMatchFocus.lineRange(2, in: text).map { String(text[$0]) }, "")
        XCTAssertEqual(SearchMatchFocus.lineRange(3, in: text).map { String(text[$0]) }, "four")
        XCTAssertNil(SearchMatchFocus.lineRange(4, in: text))
        XCTAssertNil(SearchMatchFocus.lineRange(-1, in: text))
    }

    // MARK: Note

    func testPicksTheRenderedBlockOfTheHitsParagraph() throws {
        let note = """
        ## Subjective
        Client reports sleeping poorly and feeling anxious.

        ## Plan
        Continue sleep hygiene work; review anxious thoughts next session.
        """
        let blocks = MarkdownParser.parse(note)
        let paragraphs = GlobalSearchText.paragraphs(note)
        let plan = try XCTUnwrap(paragraphs.firstIndex { $0.contains("hygiene") })
        let block = SearchMatchFocus(query: "anxious", passage: plan).noteBlock(in: blocks, note: note)
        XCTAssertEqual(block.map { blocks[$0].plainText }, "Continue sleep hygiene work; review anxious thoughts next session.")
        let first = SearchMatchFocus(query: "anxious", passage: 0).noteBlock(in: blocks, note: note)
        XCTAssertEqual(first.map { blocks[$0].plainText }, "Client reports sleeping poorly and feeling anxious.")
    }

    func testNoteMatchingIgnoresCaseAndDiacritics() {
        let note = "Intro paragraph.\n\nMet at the Café."
        let blocks = MarkdownParser.parse(note)
        XCTAssertEqual(SearchMatchFocus(query: "CAFE", passage: 1).noteBlock(in: blocks, note: note), 1)
    }

    func testNoteFallsBackToTheFirstMatchingBlockAndIsNilWithoutOne() {
        let note = "First about gardens.\n\nThen about gardens again."
        let blocks = MarkdownParser.parse(note)
        XCTAssertEqual(SearchMatchFocus(query: "garden", passage: 7).noteBlock(in: blocks, note: note), 0)
        XCTAssertNil(SearchMatchFocus(query: "lake", passage: 0).noteBlock(in: blocks, note: note))
    }

    func testListAndQuoteBlocksAreMatchedByTheirItems() {
        XCTAssertEqual(MarkdownBlock.bulleted(["a", "b"]).plainText, "a\nb")
        XCTAssertEqual(MarkdownBlock.heading(level: 2, text: "Plan").plainText, "Plan")
        XCTAssertEqual(MarkdownBlock.rule.plainText, "")
        let note = "Intro.\n\n- sleep hygiene\n- review worries"
        let blocks = MarkdownParser.parse(note)
        XCTAssertEqual(SearchMatchFocus(query: "worried", passage: 1).noteBlock(in: blocks, note: note), 1)
    }

    // MARK: Once per request

    func testShowsOncePerToken() {
        XCTAssertTrue(SearchMatchFocus.isNewRequest(token: 1, lastHandledToken: nil))
        XCTAssertFalse(SearchMatchFocus.isNewRequest(token: 1, lastHandledToken: 1))
        XCTAssertTrue(SearchMatchFocus.isNewRequest(token: 2, lastHandledToken: 1))
    }

    // MARK: Opening a hit

    func testDestinationCarriesTheMatchedPassageForTranscriptAndNoteHits() {
        let patient = Patient(name: "Jane Doe", slug: "Jane-Doe")
        let session = SessionRecord(patientId: patient.id, folderName: "s")
        func destination(_ kind: SearchKind) -> SearchHitDestination {
            SearchHitDestination(SearchHit(
                id: "x", kind: kind, patient: patient, session: session, commentID: kind == .comment ? "c" : nil,
                passage: 3, snippet: ""))
        }
        XCTAssertEqual(destination(.transcript).searchFocus(query: "garden"), SearchMatchFocus(query: "garden", passage: 3))
        XCTAssertEqual(destination(.note).searchFocus(query: "garden"), SearchMatchFocus(query: "garden", passage: 3))
        XCTAssertNil(destination(.comment).searchFocus(query: "garden"), "a comment hit flashes its comment")
        XCTAssertNil(destination(.session).searchFocus(query: "garden"))
        XCTAssertNil(destination(.sessionNotes).searchFocus(query: "garden"))
    }
}
