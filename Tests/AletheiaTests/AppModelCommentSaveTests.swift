import XCTest
@testable import Aletheia

/// Comment writes from the session screen go through `AppModel`, so a write the
/// database refuses raises the "couldn't save" notice instead of vanishing.
final class AppModelCommentSaveTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var appModel: AppModel!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        originalDataRoot = settings.dataRootURL
        settings.dataRootURL = tempRoot
        let root = tempRoot!
        let encryption = EncryptionManager(dataRootProvider: { root })
        appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()   // AppModel pointed it at this test's folder
        appModel = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAddedCommentIsSavedWithoutANotice() throws {
        let sessionID = UUID()
        let added = try XCTUnwrap(appModel.addComment(
            sessionID: sessionID, quotedText: "quote", body: "body", anchorSeconds: nil, quoteStart: nil
        ))
        XCTAssertEqual(appModel.commentStore?.comments(sessionID: sessionID).map(\.id), [added.id])
        XCTAssertNil(appModel.saveFailureSubject)

        XCTAssertTrue(appModel.updateComment(id: added.id, body: "edited"))
        XCTAssertTrue(appModel.setCommentResolved(id: added.id, resolved: true))
        XCTAssertNil(appModel.saveFailureSubject)
    }

    func testRefusedCommentEditRaisesTheNotice() {
        XCTAssertFalse(appModel.updateComment(id: UUID().uuidString, body: "edited"))
        XCTAssertEqual(appModel.saveFailureSubject, "comment")
    }

    func testRefusedResolveRaisesTheNotice() {
        XCTAssertFalse(appModel.setCommentResolved(id: UUID().uuidString, resolved: true))
        XCTAssertEqual(appModel.saveFailureSubject, "comment")
    }
}
