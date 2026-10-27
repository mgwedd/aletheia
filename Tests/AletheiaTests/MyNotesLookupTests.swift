import XCTest
@testable import Aletheia

final class MyNotesLookupTests: XCTestCase {
    private let notes = "I think Michael would benefit from X (private)\n\nSleep hygiene handout next time."

    func testRecognizesQuestionsAboutMyNotes() {
        for q in ["What have I noted about Michael?", "what’s in my notes", "Did I write anything on sleep?",
                  "Have I written about his father?", "I've noted something about work, what was it?"] {
            XCTAssertTrue(MyNotesLookup.asksAboutNotes(q), q)
        }
        for q in ["What did Michael say about sleep?", "Write a SOAP note", "Summarize the session notes for me"] {
            XCTAssertFalse(MyNotesLookup.asksAboutNotes(q), q)
        }
    }

    /// Work done with the notes goes to the model, not the lookup.
    func testRequestsThatUseTheNotesGoToTheModel() {
        for q in ["Based on my notes, what did Michael say about work?", "Turn my notes into a SOAP note",
                  "As I noted earlier, summarize the session", "Does the transcript match my notes?"] {
            XCTAssertFalse(MyNotesLookup.asksAboutNotes(q), q)
        }
    }

    func testNoteWordsAreNotSearchedFor() throws {
        let reply = try XCTUnwrap(MyNotesLookup.answer(question: "I've noted something about anxiety, what was it?", notes: notes))
        XCTAssertTrue(reply.contains("Nothing in them mentions anxiety."), reply)
    }

    func testQuotesTheParagraphThatMentionsTheName() throws {
        let reply = try XCTUnwrap(MyNotesLookup.answer(question: "What have I noted about Michael?", notes: notes))
        XCTAssertTrue(reply.contains("> I think Michael would benefit from X (private)"))
        XCTAssertFalse(reply.contains("Sleep hygiene"), "only the matching paragraph")
        XCTAssertTrue(reply.contains("the AI never reads them"))
    }

    func testShortNotesShownWholeWhenNothingMatches() throws {
        let reply = try XCTUnwrap(MyNotesLookup.answer(question: "What have I noted about anxiety?", notes: notes))
        XCTAssertTrue(reply.contains("Nothing in them mentions anxiety"))
        XCTAssertTrue(reply.contains("> Sleep hygiene handout next time."))
    }

    func testLongNotesWithNoMatchAreNotDumped() throws {
        let long = String(repeating: "Unrelated line about the weather.\n\n", count: 100)
        let reply = try XCTUnwrap(MyNotesLookup.answer(question: "What have I noted about Michael?", notes: long))
        XCTAssertTrue(reply.hasSuffix("Nothing in them mentions Michael."))
    }

    func testOtherQuestionsAndEmptyNotesGoToTheModel() {
        XCTAssertNil(MyNotesLookup.answer(question: "What did Michael say about sleep?", notes: notes))
        XCTAssertNil(MyNotesLookup.answer(question: "What have I noted about Michael?", notes: "  \n"))
    }
}
