import XCTest

/// Commenting on the transcript in the real app. The rest is in the acceptance suite.
final class CommentUITests: AcceptanceCase {
    func test_COMMENT_09_commentButtonShowsItsWholeLabel() {
        given.aSavedTranscript()

        let button = when.selectAFewWords()

        then(button).isShown()
        then(button).showsItsWholeLabel()
    }
}
