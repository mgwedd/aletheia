import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// The divider has to receive the mouse in a real window, where the transcript
/// (an NSTextView) and the comments (a scroll view) are AppKit views that take
/// the click before any SwiftUI gesture laid over them.
@MainActor
final class TranscriptSplitGripTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var ratio = TranscriptSplit.defaultRatio
        @Published var collapsed: TranscriptSplit.Side?
    }

    private struct Host: View {
        @ObservedObject var model: Model
        @State private var text = String(repeating: "[00:01] Speaker: transcript line.\n", count: 200)
        @State private var selection = ""
        @State private var range: NSRange?
        var body: some View {
            TranscriptSplitView(
                hasComments: true, commentCount: 2, ratio: $model.ratio, collapsed: $model.collapsed, revealToken: 0
            ) {
                TranscriptTextView(text: $text, comments: [], selection: $selection, selectionRange: $range)
            } comments: {
                ScrollView { Text("Resolved (2)") }
            }
        }
    }

    private let width: CGFloat = 1_000
    private var model: Model!
    private var window: NSWindow!

    override func setUp() async throws {
        model = Model()
        window = TestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        model = nil
    }

    private var dividerX: CGFloat { width * TranscriptSplit.defaultRatio }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// Long enough for the collapse/open animation to finish.
    private func settleAnimation() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func send(_ type: NSEvent.EventType, _ x: CGFloat) {
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 300), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        window.sendEvent(event)
        settle()
    }

    private func drag(from start: CGFloat, by distance: CGFloat) {
        send(.leftMouseDown, start)
        for step in 1...10 { send(.leftMouseDragged, start + distance * CGFloat(step) / 10) }
        send(.leftMouseUp, start + distance)
    }

    func testTheDividerIsHitByTheGrip() {
        let hit = window.contentView?.hitTest(NSPoint(x: dividerX + 3, y: 300))
        XCTAssertTrue(hit is PaneDividerGripView, "hit \(String(describing: hit))")
    }

    func testTheWholeSharedGripWidthIsHit() {
        for x in [dividerX - PaneDivider.gripLead + 0.5, dividerX + PaneDivider.gripWidth - PaneDivider.gripLead - 2] {
            let hit = window.contentView?.hitTest(NSPoint(x: x, y: 300))
            XCTAssertTrue(hit is PaneDividerGripView, "x \(x) hit \(String(describing: hit))")
        }
    }

    func testDraggingTheDividerResizesTheSplit() {
        drag(from: dividerX + 3, by: -100)
        XCTAssertEqual(model.ratio, (dividerX - 100) / width, accuracy: 0.01)
        XCTAssertNil(model.collapsed)
    }

    func testDraggingTheCommentsTooNarrowSnapsThemClosed() {
        let comments = width - dividerX - TranscriptSplit.dividerWidth
        let past = comments - (TranscriptSplit.minComments - TranscriptSplit.collapseSlack) + 20
        drag(from: dividerX + 3, by: past)
        XCTAssertEqual(model.collapsed, .comments)
        settleAnimation()
        XCTAssertFalse(window.contentView?.hitTest(NSPoint(x: dividerX + 3, y: 300)) is PaneDividerGripView)
    }

    func testDraggingTheTranscriptTooNarrowSnapsItClosed() {
        let past = dividerX - (TranscriptSplit.minTranscript - TranscriptSplit.collapseSlack) + 20
        drag(from: dividerX + 3, by: -past)
        XCTAssertEqual(model.collapsed, .transcript)
    }

    // MARK: - Dragging a collapsed strip back open

    private var commentsStripEdgeX: CGFloat { width - TranscriptSplit.stripWidth + 3 }
    private var transcriptStripEdgeX: CGFloat { TranscriptSplit.stripWidth - 3 }

    func testTheCollapsedCommentsStripEdgeIsHitByTheGrip() {
        model.collapsed = .comments
        settleAnimation()
        let hit = window.contentView?.hitTest(NSPoint(x: commentsStripEdgeX, y: 300))
        XCTAssertTrue(hit is PaneDividerGripView, "hit \(String(describing: hit))")
    }

    func testDraggingTheCollapsedCommentsStripOutwardsReopensThem() {
        model.collapsed = .comments
        settleAnimation()
        drag(from: commentsStripEdgeX, by: -300)
        settleAnimation()
        XCTAssertNil(model.collapsed)
        // The divider followed the mouse: comments are about 300 + 24 wide.
        let comments = (1 - model.ratio) * (width - TranscriptSplit.dividerWidth)
        XCTAssertEqual(comments, 300 + TranscriptSplit.stripWidth - 3, accuracy: 20)
    }

    func testDraggingTheCollapsedTranscriptStripOutwardsReopensIt() {
        model.collapsed = .transcript
        settleAnimation()
        drag(from: transcriptStripEdgeX, by: 300)
        settleAnimation()
        XCTAssertNil(model.collapsed)
        XCTAssertEqual(model.ratio * (width - TranscriptSplit.dividerWidth), 300 + TranscriptSplit.stripWidth - 3, accuracy: 20)
    }

    func testAShortDragOnTheStripStaysCollapsed() {
        model.collapsed = .comments
        settleAnimation()
        drag(from: commentsStripEdgeX, by: -20)
        XCTAssertEqual(model.collapsed, .comments)
    }

    func testClickingTheStripEdgeRestoresTheDefault() {
        model.collapsed = .comments
        model.ratio = 0.4
        settleAnimation()
        send(.leftMouseDown, commentsStripEdgeX)
        send(.leftMouseUp, commentsStripEdgeX)
        XCTAssertNil(model.collapsed)
        XCTAssertEqual(model.ratio, TranscriptSplit.defaultRatio, accuracy: 1e-9)
    }
}
