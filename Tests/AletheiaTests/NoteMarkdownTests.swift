import XCTest
@testable import Aletheia

/// `NoteMarkdown.tidy`: the repairs that make a model's chat-style note read as
/// a set document, and the lines it must leave alone.
final class NoteMarkdownTests: XCTestCase {
    func testDropsAnnouncingPreamble() {
        let note = "Here is a concise narrative clinical summary of the session:\nThe client reported feeling upset."
        XCTAssertEqual(NoteMarkdown.tidy(note), "The client reported feeling upset.")
    }

    func testKeepsPreambleShapedLineWhenNothingFollows() {
        XCTAssertEqual(NoteMarkdown.tidy("Here is the summary:"), "Here is the summary:")
    }

    func testKeepsOrdinaryFirstLine() {
        let note = "The client arrived on time:\nshe said traffic was light."
        XCTAssertTrue(NoteMarkdown.tidy(note).hasPrefix("The client arrived on time:"))
    }

    func testSeparatesSingleNewlineParagraphs() {
        let note = "First paragraph.\nSecond paragraph.\nThird paragraph."
        XCTAssertEqual(NoteMarkdown.tidy(note), "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.")
    }

    func testStandaloneLabelBecomesSmallHeading() {
        let note = "Follow-ups to revisit next session:\n- Couples therapy\n- Sleep"
        XCTAssertEqual(NoteMarkdown.tidy(note), "### Follow-ups to revisit next session\n- Couples therapy\n- Sleep")
    }

    func testLeadInLabelIsBolded() {
        let note = "Mood/affect observations: The client reported feeling \"upset\"."
        XCTAssertEqual(NoteMarkdown.tidy(note), "**Mood/affect observations:** The client reported feeling \"upset\".")
    }

    func testClauseBeforeColonIsNotALabel() {
        for line in ["The client said: I can't sleep.", "She reported: poor appetite.", "Client stated: tired."] {
            XCTAssertEqual(NoteMarkdown.tidy(line), line)
        }
    }

    func testTimesAndQuotesAreNotLabels() {
        for line in ["Session began at 10:30 as planned.", "[00:16] Therapist: No problem."] {
            XCTAssertEqual(NoteMarkdown.tidy(line), line)
        }
    }

    func testLeavesListsHeadingsQuotesAndCodeAlone() {
        let note = """
        ## Plan
        - First item
        - Second item
        1. One
        2. Two
        > Quoted line
        > Another
        ```
        code line
        Label: inside code
        ```
        """
        XCTAssertEqual(NoteMarkdown.tidy(note), note)
    }

    func testFullScreenshotNote() {
        let note = """
        Here is a concise narrative clinical summary of the session:
        The therapist began the session.
        Notable statements include the client's uncertainty.
        Mood/affect observations: The client reported feeling "upset".
        Follow-ups to revisit next session:
        - The client's feelings
        - Couples therapy
        """
        let expected = """
        The therapist began the session.

        Notable statements include the client's uncertainty.

        **Mood/affect observations:** The client reported feeling "upset".

        ### Follow-ups to revisit next session
        - The client's feelings
        - Couples therapy
        """
        XCTAssertEqual(NoteMarkdown.tidy(note), expected)
    }

    func testIsIdempotent() {
        let note = "Here is the note:\nOne.\nTwo.\nPlan: Continue weekly.\nNext steps:\n- Call"
        let once = NoteMarkdown.tidy(note)
        XCTAssertEqual(NoteMarkdown.tidy(once), once)
    }

    func testParsesIntoSeparateBlocks() {
        let blocks = MarkdownParser.parse(NoteMarkdown.tidy("One.\nTwo.\nNext steps:\n- Call"))
        XCTAssertEqual(blocks, [
            .paragraph("One."),
            .paragraph("Two."),
            .heading(level: 3, text: "Next steps"),
            .bulleted(["Call"]),
        ])
    }
}
