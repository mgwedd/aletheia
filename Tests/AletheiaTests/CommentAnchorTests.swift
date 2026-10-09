import XCTest
@testable import Aletheia

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

    /// The position of the quote round-trips through SQLite, so two comments on
    /// the same repeated word keep distinct anchors; absent it stays nil.
    func testQuoteStartRoundTripsAndDefaultsToNil() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        store.addComment(sessionID: session, quotedText: "Therapist", body: "first", anchorSeconds: 0, quoteStart: 8, now: t0)
        store.addComment(sessionID: session, quotedText: "Therapist", body: "second", anchorSeconds: 40, quoteStart: 83, now: t0.addingTimeInterval(1))
        store.addComment(sessionID: session, quotedText: "Therapist", body: "legacy-style", now: t0.addingTimeInterval(2))

        let comments = store.comments(sessionID: session)
        XCTAssertEqual(comments.map(\.quoteStart), [8, 83, nil])
    }
}
