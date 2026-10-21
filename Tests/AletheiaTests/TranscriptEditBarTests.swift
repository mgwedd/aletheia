import XCTest
@testable import Aletheia

final class TranscriptEditBarTests: XCTestCase {
    func testNoSaveOrDiscardWithoutEdits() {
        XCTAssertFalse(TranscriptEditBar.showsEditControls(isDirty: false))
        XCTAssertNil(TranscriptEditBar.statusNote(isDirty: false))
    }

    func testSaveAndDiscardAppearWithEdits() {
        XCTAssertTrue(TranscriptEditBar.showsEditControls(isDirty: true))
        XCTAssertEqual(TranscriptEditBar.statusNote(isDirty: true), "Edits to the transcript are not saved yet")
    }

    /// The "select any part of the transcript" hint is gone: commenting explains itself.
    func testTranscriptBarHasNoCommentHint() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/SessionDetailView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(source.contains("Select any part of the transcript to comment"))
    }
}
