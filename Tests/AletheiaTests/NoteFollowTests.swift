import XCTest
@testable import Aletheia

/// NOTE-21: a note being written keeps its newest text in view until the
/// therapist scrolls up, and goes to its end when it finishes.
final class NoteFollowTests: XCTestCase {
    func testNewTextScrollsWhileANoteIsWritten() {
        var follow = NoteFollow()
        XCTAssertTrue(follow.update(writing: true, textGrew: true))
        XCTAssertTrue(follow.update(writing: true, textGrew: true))
    }

    func testNothingScrollsWhenTheTextDidNotChange() {
        var follow = NoteFollow()
        _ = follow.update(writing: true, textGrew: true)
        XCTAssertFalse(follow.update(writing: true, textGrew: false))
    }

    func testScrollingUpStopsFollowing() {
        var follow = NoteFollow()
        _ = follow.update(writing: true, textGrew: true)
        follow.scrolled(distanceFromEnd: 300)
        XCTAssertFalse(follow.isFollowing)
        XCTAssertFalse(follow.update(writing: true, textGrew: true))
    }

    func testComingBackNearTheEndFollowsAgain() {
        var follow = NoteFollow()
        _ = follow.update(writing: true, textGrew: true)
        follow.scrolled(distanceFromEnd: 300)
        follow.scrolled(distanceFromEnd: NoteFollow.nearEnd)
        XCTAssertTrue(follow.isFollowing)
        XCTAssertTrue(follow.update(writing: true, textGrew: true))
    }

    func testFinishingGoesToTheEndEvenAfterScrollingUp() {
        var follow = NoteFollow()
        _ = follow.update(writing: true, textGrew: true)
        follow.scrolled(distanceFromEnd: 300)
        XCTAssertTrue(follow.update(writing: false, textGrew: true))
    }

    func testAFinishedNoteIsLeftWhereItIs() {
        var follow = NoteFollow()
        XCTAssertFalse(follow.update(writing: false, textGrew: true))
        _ = follow.update(writing: true, textGrew: true)
        _ = follow.update(writing: false, textGrew: false)
        XCTAssertFalse(follow.update(writing: false, textGrew: true), "an edit after the note finished scrolled the view")
    }

    func testANewNoteIsFollowedAfresh() {
        var follow = NoteFollow()
        _ = follow.update(writing: true, textGrew: true)
        follow.scrolled(distanceFromEnd: 300)
        _ = follow.update(writing: false, textGrew: false)
        XCTAssertTrue(follow.update(writing: true, textGrew: true))
    }
}
