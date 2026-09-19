import XCTest
@testable import Aletheia

final class SuggestedQuestionsTests: XCTestCase {
    func testBothListsAreNonEmptyAndDistinct() {
        XCTAssertFalse(SuggestedQuestions.session.isEmpty)
        XCTAssertFalse(SuggestedQuestions.patient.isEmpty)
        XCTAssertEqual(Set(SuggestedQuestions.session).count, SuggestedQuestions.session.count)
        XCTAssertEqual(Set(SuggestedQuestions.patient).count, SuggestedQuestions.patient.count)
    }

    func testQuestionsAreProperlyPhrased() {
        for question in SuggestedQuestions.session + SuggestedQuestions.patient {
            XCTAssertFalse(question.trimmingCharacters(in: .whitespaces).isEmpty)
            XCTAssertTrue(question.hasSuffix("?") || question.hasSuffix("."), "‘\(question)’ should read as a prompt")
        }
    }
}
