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

    /// A legacy scroller takes its width from the content; an overlay one takes none.
    func testTheContentLeavesRoomOnlyForAScrollerThatTakesSpace() {
        XCTAssertEqual(BoundedScrollLayout.scrollerGutter(style: .overlay), 0)
        XCTAssertEqual(BoundedScrollLayout.scrollerGutter(style: .legacy),
                       NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
        XCTAssertGreaterThan(BoundedScrollLayout.scrollerGutter(style: .legacy), 0)
    }

    /// The content is as wide whether it scrolls or not, so a scroller
    /// appearing never rewraps it, whichever kind of scroller the Mac shows.
    func testTheContentKeepsItsWidthWhenItGrowsLongEnoughToScroll() {
        func contentWidth(lines: Int, gutter: CGFloat) -> CGFloat {
            var measured: CGFloat = 0
            let view = BoundedScroll(scrollerGutter: gutter) {
                VStack(spacing: 0) { ForEach(0..<lines, id: \.self) { Text("line \($0)").frame(height: 20) } }
                    .frame(maxWidth: .infinity)
                    .background(GeometryReader { geo in Color.clear
                        .onAppear { measured = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in measured = width } })
            }
            let host = NSHostingView(rootView: view.frame(width: 300, height: 200))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return measured
        }
        for gutter in [BoundedScrollLayout.scrollerGutter(style: .overlay), BoundedScrollLayout.scrollerGutter(style: .legacy)] {
            let short = contentWidth(lines: 2, gutter: gutter), long = contentWidth(lines: 200, gutter: gutter)
            XCTAssertEqual(short, 300 - gutter, accuracy: 1, "gutter \(gutter)")
            XCTAssertEqual(long, short, accuracy: 1, "gutter \(gutter)")
        }
    }

    /// The note tab's reader is an AppKit scroll view, which, like
    /// BoundedScroll, doesn't ask for its text's height.
    func testTheNoteReaderDoesNotAskForItsTextsHeight() {
        let note = (0..<400).map { "Line \($0) of a long note." }.joined(separator: "\n\n")
        let host = NSHostingView(rootView: NoteReaderView(
            text: note, comments: [], selection: .constant(""), selectionRange: .constant(nil)))
        XCTAssertLessThan(host.fittingSize.height, 2_000)
    }

    /// A long conversation in the Ask tab has the same problem as a long note.
    func testChatConversationUsesBoundedScroll() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/ChatPaneView.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let marker = try XCTUnwrap(source.range(of: "VStack(alignment: .leading, spacing: 20)"))
        XCTAssertTrue(source[..<marker.lowerBound].suffix(400).contains("BoundedScroll {"))
    }
}
