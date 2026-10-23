import XCTest
@testable import Aletheia

final class ContextBudgetTests: XCTestCase {
    func testUntrustedSegmentsAreCapped() {
        let budget = ContextBudget(tokens: 8_192)
        let cap = budget.untrustedSegmentCharacters
        XCTAssertGreaterThan(cap, 0)
        XCTAssertLessThan(cap, budget.availableCharacters(reserving: 0))

        let huge = String(repeating: "a", count: cap * 10)
        for kind in [UntrustedText.Kind.notes, .comments, .background, .conversation, .digest, .draft, .question] {
            let text = UntrustedText(kind, huge, budget: budget).text
            XCTAssertLessThanOrEqual(ContextBudget.weightedLength(of: text), cap + UntrustedText.cutMarker.count, "\(kind)")
            XCTAssertTrue(text.hasSuffix(UntrustedText.cutMarker), "\(kind)")
        }
        let small = UntrustedText(.notes, "short note", budget: budget).text
        XCTAssertEqual(small, "short note")
    }

    func testWholeTranscriptsAreLeftToTheBudgetCheck() {
        let budget = ContextBudget(tokens: 8_192)
        let long = String(repeating: "word ", count: budget.untrustedSegmentCharacters)
        XCTAssertEqual(UntrustedText(.transcript, long, budget: budget).text, long)
        XCTAssertEqual(UntrustedText(.material, long, budget: budget).text, long)
    }

    func testHugeCommentCannotCrowdOutTheInstructions() {
        let comment = String(repeating: "x", count: 5_000_000)
        let prompt = Prompts.sessionChat(transcript: "[00:01] You: hi", comments: [comment], history: [], question: "Q?")
        XCTAssertLessThan(prompt.count, ContextBudget.current.availableCharacters(reserving: 0))
        XCTAssertTrue(prompt.contains(Prompts.untrustedDataRule))
    }
}
