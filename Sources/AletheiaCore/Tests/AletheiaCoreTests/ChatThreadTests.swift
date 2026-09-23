import XCTest
@testable import AletheiaCore

final class ChatThreadTests: XCTestCase {
    func testDeriveTitleKeepsShortQuestionVerbatim() {
        XCTAssertEqual(ChatThread.deriveTitle(from: "How has sleep been?"), "How has sleep been?")
    }

    func testDeriveTitleCollapsesWhitespaceAndNewlines() {
        XCTAssertEqual(ChatThread.deriveTitle(from: "  How   has\nsleep been?  "), "How has sleep been?")
    }

    func testDeriveTitleClipsOnWordBoundaryWithEllipsis() {
        let long = "What did the patient say about their relationship with their mother over the last month"
        let title = ChatThread.deriveTitle(from: long, maxLength: 40)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThanOrEqual(title.count, 41) // 40 + ellipsis
        XCTAssertFalse(title.dropLast().hasSuffix(" "), "no trailing space before the ellipsis")
        XCTAssertTrue(long.hasPrefix(String(title.dropLast())), "the title is a prefix of the question")
    }

    func testDeriveTitleEmptyFallsBack() {
        XCTAssertEqual(ChatThread.deriveTitle(from: "   \n  "), "New chat")
    }

    func testAutoTitleUsesFirstUserMessage() {
        let messages = [
            ChatMessage(role: .assistant, text: "Hi, ask me anything."),
            ChatMessage(role: .user, text: "Summarize the risk themes"),
            ChatMessage(role: .assistant, text: "…"),
        ]
        XCTAssertEqual(ChatThread.autoTitle(from: messages), "Summarize the risk themes")
    }

    func testAutoTitleNoUserMessageFallsBack() {
        XCTAssertEqual(ChatThread.autoTitle(from: []), "New chat")
    }

    func testDisplayTitlePrefersExplicitTitle() {
        let thread = ChatThread(title: "Medication history",
                                messages: [ChatMessage(role: .user, text: "when did we start sertraline")])
        XCTAssertEqual(thread.displayTitle, "Medication history")
    }

    func testDisplayTitleFallsBackToAutoTitleWhenBlank() {
        let thread = ChatThread(title: "   ",
                                messages: [ChatMessage(role: .user, text: "when did we start sertraline")])
        XCTAssertEqual(thread.displayTitle, "when did we start sertraline")
    }
}
