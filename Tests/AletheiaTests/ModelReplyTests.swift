import XCTest
@testable import Aletheia

/// A saved reply as plain answer text: the model's hidden reasoning and its
/// chat-template markers are gone, ordinary text is left alone. Synthetic text only.
final class ModelReplyTests: XCTestCase {
    // MARK: - Reasoning spans

    func testClosedMedGemmaReasoningSpanIsRemoved() {
        let reply = "<unused94>thought\nThe therapist asks about sleep. Check the transcript first.<unused95>She slept badly most nights."
        XCTAssertEqual(ModelReply.plain(reply), "She slept badly most nights.")
    }

    func testReasoningSpanInTheMiddleKeepsTheTextOnBothSides() {
        let reply = "First part. <unused94>thought\nplanning<unused95> Second part."
        XCTAssertEqual(ModelReply.plain(reply), "First part.  Second part.")
    }

    func testSeveralReasoningSpansAreAllRemoved() {
        let reply = "<unused94>thought\none<unused95>A.\n<unused94>thought\ntwo<unused95>B."
        XCTAssertEqual(ModelReply.plain(reply), "A.\nB.")
    }

    func testUnclosedReasoningSpanIsRemovedToTheEnd() {
        let reply = "Here is the answer.\n<unused94>thought\nNow I should double-check the dates and"
        XCTAssertEqual(ModelReply.plain(reply), "Here is the answer.")
    }

    func testThinkSpanIsRemoved() {
        XCTAssertEqual(ModelReply.plain("<think>weigh the options</think>\nTake the first one."), "Take the first one.")
    }

    func testUnclosedThinkSpanIsRemovedToTheEnd() {
        XCTAssertEqual(ModelReply.plain("Answer first.<think>and then I kept thinking"), "Answer first.")
    }

    func testAReplyThatIsOnlyReasoningBecomesEmpty() {
        XCTAssertEqual(ModelReply.plain("<unused94>thought\nOnly thinking, no answer yet"), "")
        XCTAssertEqual(ModelReply.plain("<unused94>thought\nOnly thinking<unused95>"), "")
        XCTAssertEqual(ModelReply.plain("<think>only thinking</think>"), "")
    }

    // MARK: - Template markers

    func testStrayTemplateMarkersAreRemoved() {
        XCTAssertEqual(ModelReply.plain("<start_of_turn>model\nHello there.<end_of_turn>"), "Hello there.")
        XCTAssertEqual(ModelReply.plain("<start_of_turn>Hello"), "Hello")
        XCTAssertEqual(ModelReply.plain("<bos>Hi<eos>"), "Hi")
        XCTAssertEqual(ModelReply.plain("<unused5>Hi<unused12>"), "Hi")
        XCTAssertEqual(ModelReply.plain("Done.<|im_end|>"), "Done.")
    }

    func testGemma4ChannelAndTurnMarkersAreRemoved() {
        XCTAssertEqual(ModelReply.plain("<|channel>thought\nCheck the dates first.<channel|>She slept badly."), "She slept badly.")
        XCTAssertEqual(ModelReply.plain("She slept badly.<|channel>thought\nand then"), "She slept badly.")
        XCTAssertEqual(ModelReply.plain("<|turn>model\nHello there.<turn|>"), "Hello there.")
    }

    func testMarkersAndReasoningTogether() {
        let reply = "<start_of_turn>model\n<unused94>thought\nplan<unused95>The plan is to meet weekly.<end_of_turn>"
        XCTAssertEqual(ModelReply.plain(reply), "The plan is to meet weekly.")
    }

    // MARK: - Ordinary text

    func testOrdinaryTextIsUntouched() {
        for text in [
            "She said a < b and c > d.",
            "I <3 this plan",
            "Scores went from 7 to <5 on the scale.",
            "Use the <b>bold</b> tag.",
            "- one\n- two\n\n**Bold** and `code`.",
            "She thought about it for a while.",
        ] {
            XCTAssertEqual(ModelReply.plain(text), text, text)
        }
    }

    func testOnlySurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(ModelReply.plain("\n  Line one.\n\nLine two.  \n"), "Line one.\n\nLine two.")
        XCTAssertEqual(ModelReply.plain(""), "")
    }

    // MARK: - Where saved replies are replayed

    /// A reply saved with its reasoning goes back to the model without it.
    func testRecentReplaysASavedAnswerWithoutItsReasoning() {
        let history = [
            ChatMessage(role: .user, text: "How did she sleep? <end_of_turn>"),
            ChatMessage(role: .assistant, text: "<unused94>thought\nCheck the sleep lines.<unused95>She slept badly.<end_of_turn>"),
            ChatMessage(role: .user, text: "And work?"),
        ]
        XCTAssertEqual(PromptTurn.recent(history, question: "And work?"), [
            PromptTurn(role: .user, text: "How did she sleep? <end_of_turn>"),
            PromptTurn(role: .assistant, text: "She slept badly."),
        ], "only the model's own replies are cleaned, never the therapist's words")
    }

    func testRecentGivesAnAnswerThatWasOnlyReasoningAsEmptyText() {
        let history = [
            ChatMessage(role: .user, text: "Q1"),
            ChatMessage(role: .assistant, text: "<unused94>thought\nnever finished"),
            ChatMessage(role: .user, text: "Q2"),
        ]
        let turns = PromptTurn.recent(history, question: "Q2")
        XCTAssertEqual(turns.map(\.text), ["Q1", ""])
    }

    /// The summary that stands in for earlier messages is cleaned the same way.
    func testEarlierConversationSummaryHasNoReasoning() {
        let history = [
            ChatMessage(role: .user, text: "Be brief."),
            ChatMessage(role: .summary, text: "<unused94>thought\nlist the topics<unused95>Asked about sleep and work."),
            ChatMessage(role: .user, text: "Next?"),
        ]
        let earlier = Prompts.earlierConversation(history)
        XCTAssertTrue(earlier.contains("<summary>\nAsked about sleep and work.\n</summary>"), earlier)
        XCTAssertFalse(earlier.contains("unused"))
        XCTAssertFalse(earlier.contains("thought"))
        XCTAssertFalse(earlier.contains("list the topics"))
        XCTAssertTrue(earlier.contains("- Be brief."))
    }

    func testEarlierConversationLeavesACleanSummaryAsItWas() {
        let history = [ChatMessage(role: .summary, text: "Asked about sleep.")]
        XCTAssertTrue(Prompts.earlierConversation(history).contains("<summary>\nAsked about sleep.\n</summary>"))
    }
}
