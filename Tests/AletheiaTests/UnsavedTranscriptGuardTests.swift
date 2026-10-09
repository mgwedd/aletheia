import XCTest
@testable import Aletheia

@MainActor
final class UnsavedTranscriptGuardTests: XCTestCase {
    func testDefaultsToNothingUnsaved() {
        let guardian = UnsavedTranscriptGuard()
        XCTAssertFalse(guardian.hasUnsavedEdits)
        XCTAssertTrue(guardian.save())
    }

    func testReportsAndActsOnTheAttachedSession() {
        let guardian = UnsavedTranscriptGuard()
        var dirty = true
        var discarded = false
        guardian.attach(
            dirty: { dirty },
            save: { dirty = false; return true },
            discard: { dirty = false; discarded = true }
        )
        XCTAssertTrue(guardian.hasUnsavedEdits)
        XCTAssertTrue(guardian.save())
        XCTAssertFalse(guardian.hasUnsavedEdits)

        dirty = true
        guardian.discard()
        XCTAssertTrue(discarded)
        XCTAssertFalse(guardian.hasUnsavedEdits)
    }

    func testFailedSaveReportsFailureAndStaysDirty() {
        let guardian = UnsavedTranscriptGuard()
        guardian.attach(dirty: { true }, save: { false }, discard: {})
        XCTAssertFalse(guardian.save())
        XCTAssertTrue(guardian.hasUnsavedEdits)
    }

    func testDetachForgetsTheSession() {
        let guardian = UnsavedTranscriptGuard()
        guardian.attach(dirty: { true }, save: { false }, discard: {})
        guardian.detach()
        XCTAssertFalse(guardian.hasUnsavedEdits)
    }

    func testStashedDraftComesBackOnceAndOnlyWhenItDiffers() {
        let id = UUID()
        UnsavedTranscriptDrafts.stash("edited", saved: "original", for: id)
        XCTAssertEqual(UnsavedTranscriptDrafts.take(for: id), "edited")
        XCTAssertNil(UnsavedTranscriptDrafts.take(for: id), "taken once")

        UnsavedTranscriptDrafts.stash("edited", saved: "original", for: id)
        UnsavedTranscriptDrafts.stash("original", saved: "original", for: id)
        XCTAssertNil(UnsavedTranscriptDrafts.take(for: id), "a draft that matches the saved text is dropped")
    }

    func testAnEmptiedDraftIsStillRemembered() {
        let id = UUID()
        UnsavedTranscriptDrafts.stash("", saved: "original", for: id)
        XCTAssertEqual(UnsavedTranscriptDrafts.take(for: id), "")
    }
}
