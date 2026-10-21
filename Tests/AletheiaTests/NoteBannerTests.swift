import XCTest
@testable import Aletheia

final class NoteBannerTests: XCTestCase {
    /// The Notes tab does not carry an "AI draft" banner above the note.
    func testNotesTabHasNoAIDraftBanner() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/SessionDetailView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(source.contains("Chip(\"AI draft\""))
        XCTAssertFalse(source.contains("Drafted from the transcript and your notes"))
    }
}
