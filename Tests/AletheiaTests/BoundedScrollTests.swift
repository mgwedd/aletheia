import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class BoundedScrollTests: XCTestCase {
    private var tallContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<400, id: \.self) { index in
                Text("line \(index)").frame(height: 20)
            }
        }
    }

    /// The premise: a bare ScrollView reports its content's height (about 8000 pt
    /// here), which is what lets a long note push the window past the screen.
    func testABareScrollViewAsksForItsContentsHeight() {
        let host = NSHostingView(rootView: ScrollView { tallContent })
        XCTAssertGreaterThan(host.fittingSize.height, 2_000)
    }

    func testBoundedScrollDoesNotAskForItsContentsHeight() {
        let host = NSHostingView(rootView: BoundedScroll { tallContent })
        XCTAssertLessThanOrEqual(host.fittingSize.height, BoundedScrollLayout.idealHeight + 1)
    }

    func testBoundedScrollStillFillsTheSpaceItIsGiven() {
        let host = NSHostingView(rootView: BoundedScroll { tallContent }.frame(width: 300, height: 700))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, 700, accuracy: 1)
    }

    /// The note tab uses it, rather than a bare ScrollView.
    func testNoteBodyUsesBoundedScroll() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/SessionDetailView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "MarkdownMessageView(text: summaryText, style: .note)"))
        let before = source[..<marker.lowerBound].suffix(200)
        XCTAssertTrue(before.contains("BoundedScroll {"), "the note body should sit in a BoundedScroll")
    }

    /// A long conversation in the Ask tab has the same problem as a long note.
    func testChatConversationUsesBoundedScroll() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/ChatPaneView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "LazyVStack(alignment: .leading, spacing: 20)"))
        XCTAssertTrue(source[..<marker.lowerBound].suffix(120).contains("BoundedScroll {"))
    }
}
