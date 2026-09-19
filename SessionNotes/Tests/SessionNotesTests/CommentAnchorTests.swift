import XCTest
@testable import SessionNotes

/// The time anchor on a margin comment: it round-trips and defaults to nil.
///
/// (This used to also cover a pre-anchor bespoke `comments` table upgrading
/// in place on open — moot now that `CommentStore` sits on the generic
/// `PersistenceCore` records table rather than owning its own schema; see
/// Arch v2 (2), #65/#74/#76.)
final class CommentAnchorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAnchorRoundTripsAndDefaultsToNil() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        store.addComment(sessionID: session, quotedText: "barely slept", body: "note", anchorSeconds: 42)
        store.addComment(sessionID: session, quotedText: "", body: "no anchor")

        let comments = store.comments(sessionID: session)
        XCTAssertEqual(comments.first?.anchorSeconds, 42)
        XCTAssertNil(comments.last?.anchorSeconds)
    }
}
