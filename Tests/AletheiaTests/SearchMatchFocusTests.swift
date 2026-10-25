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

    private func rendered(_ note: String) -> String {
        NoteReaderView.rendered(note).string
    }

    private func flashedInNote(_ query: String, passage: Int, in note: String) -> String? {
        let text = rendered(note)
        return SearchMatchFocus(query: query, passage: passage).noteRange(in: text, note: note)
            .map { (text as NSString).substring(with: $0) }
    }

    func testFlashesTheMatchInTheRenderedLineOfTheHitsParagraph() throws {
        let note = """
        ## Subjective
        Client reports sleeping poorly and feeling **anxious**.

        ## Plan
        Continue sleep hygiene work; review anxious thoughts next session.
        """
        let text = rendered(note)
        let paragraphs = GlobalSearchText.paragraphs(note)
        let plan = try XCTUnwrap(paragraphs.firstIndex { $0.contains("hygiene") })
        let range = try XCTUnwrap(SearchMatchFocus(query: "anxious", passage: plan).noteRange(in: text, note: note))
        XCTAssertEqual((text as NSString).substring(with: range), "anxious")
        let planLine = (text as NSString).range(of: "Continue sleep hygiene")
        XCTAssertGreaterThan(range.location, planLine.location, "the match in the Plan line, not the first one")

        let subjective = try XCTUnwrap(paragraphs.firstIndex { $0.contains("sleeping poorly") })
        let first = try XCTUnwrap(SearchMatchFocus(query: "anxious", passage: subjective).noteRange(in: text, note: note))
        XCTAssertLessThan(first.location, planLine.location)
    }

    func testNoteMatchingIgnoresCaseAndDiacritics() {
        XCTAssertEqual(flashedInNote("CAFE", passage: 1, in: "Intro paragraph.\n\nMet at the Café."), "Café")
    }

    func testNoteFallsBackToTheFirstMatchingLineAndIsNilWithoutOne() {
        let note = "First about gardens.\n\nThen about gardens again."
        let text = rendered(note)
        XCTAssertEqual(SearchMatchFocus(query: "garden", passage: 7).noteRange(in: text, note: note)?.location,
                       (text as NSString).range(of: "gardens").location)
        XCTAssertNil(SearchMatchFocus(query: "lake", passage: 0).noteRange(in: text, note: note))
    }

    func testListItemsAreMatchedInTheRenderedText() {
        XCTAssertEqual(flashedInNote("worried", passage: 1, in: "Intro.\n\n- sleep hygiene\n- review worries"), "worries")
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
