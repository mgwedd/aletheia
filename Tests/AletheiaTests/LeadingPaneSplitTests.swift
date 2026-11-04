import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// A split whose pane never collapses: dragged far past its narrowest it still
/// gives way, then springs back to the narrowest when let go.
@MainActor
final class LeadingPaneSplitTests: XCTestCase {
    private final class Width: ObservableObject {
        @Published var value = Double(ChatThreadsLayout.idealWidth)
    }

    private struct Host: View {
        @ObservedObject var width: Width

        var body: some View {
            LeadingPaneSplit(
                width: $width.value,
                limit: { ChatThreadsLayout.width(proposed: $0, total: $1) },
                dividerID: "chat-threads-divider", dividerLabel: "Chats list width"
            ) {
                Color.clear
            } content: {
                Color.clear
            }
        }
    }

    private var window: NSWindow!
    private var width: Width!

    override func setUp() async throws {
        width = Width()
        window = TestWindow(contentViewController: NSHostingController(rootView: Host(width: width)))
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 500))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private var grip: PaneDividerGripView? {
        func walk(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(walk) }
        return walk(window.contentView!).lazy.compactMap { $0 as? PaneDividerGripView }.first
    }

    private var edgeX: CGFloat? {
        grip.map { $0.convert($0.bounds, to: nil).minX + PaneDivider.gripLead }
    }

    func testDraggingFarLeftNeverCollapsesAndSpringsBackToTheNarrowest() throws {
        grip?.onDrag(-500)
        settle()
        XCTAssertEqual(grip?.accessibilityIdentifier(), "chat-threads-divider", "the divider stays")
        XCTAssertLessThan(try XCTUnwrap(edgeX), ChatThreadsLayout.minWidth - 10, "the edge gives way under the narrowest")
        grip?.onEnd()
        settle()
        XCTAssertEqual(width.value, Double(ChatThreadsLayout.minWidth))
        XCTAssertEqual(try XCTUnwrap(edgeX), ChatThreadsLayout.minWidth, accuracy: 1)
    }

    func testTheWidthStaysWithinItsLimits() {
        XCTAssertEqual(ChatThreadsLayout.width(proposed: 0, total: 900), ChatThreadsLayout.minWidth)
        XCTAssertEqual(ChatThreadsLayout.width(proposed: 10_000, total: 900), ChatThreadsLayout.maxWidth)
        XCTAssertEqual(ChatThreadsLayout.width(proposed: 250, total: 900), 250)
        XCTAssertEqual(ChatThreadsLayout.width(proposed: 300, total: 600), 600 - ChatThreadsLayout.chatMinWidth)
    }
}
