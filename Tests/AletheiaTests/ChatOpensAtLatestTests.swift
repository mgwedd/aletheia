import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// The session Ask tab and the patient chat both render `ChatPaneView`; its
/// message list must open at the latest message, not the first.
@MainActor
final class ChatOpensAtLatestTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var messages: [ChatMessage]
        init(_ messages: [ChatMessage]) { self.messages = messages }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            ChatPaneView(
                title: "this session",
                messages: $model.messages,
                isSending: false,
                onSend: { _ in },
                voiceInput: FakeVoiceInput()
            )
        }
    }

    private var window: NSWindow!

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    private func thread(_ n: Int, tag: String) -> [ChatMessage] {
        (0..<n).map {
            ChatMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        text: "\(tag) \($0) " + String(repeating: "lorem ipsum dolor sit amet ", count: 12))
        }
    }

    private func open(_ model: Model) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    private func settle() {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func chatScrollView() -> NSScrollView? {
        func walk(_ v: NSView) -> [NSScrollView] {
            let rest = v.subviews.flatMap(walk)
            if let s = v as? NSScrollView { return [s] + rest }
            return rest
        }
        // The conversation is the largest scroll view (the composer's field is small).
        return window.contentView.map(walk)?.max { $0.frame.height < $1.frame.height }
    }

    private func assertAtBottom(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let scroll = chatScrollView(), let doc = scroll.documentView else {
            return XCTFail("no scroll view", file: file, line: line)
        }
        let visible = scroll.contentView.documentVisibleRect
        XCTAssertGreaterThan(doc.frame.height, visible.height * 2, "content should overflow", file: file, line: line)
        // Lazy rows are estimated until measured, so allow a little drift.
        XCTAssertGreaterThan(visible.minY, 100, "not at the top", file: file, line: line)
        XCTAssertEqual(visible.maxY, doc.frame.height, accuracy: 20, message, file: file, line: line)
    }

    func testOpensAtLatestMessage() {
        open(Model(thread(40, tag: "A")))
        assertAtBottom("opens scrolled to the latest message")
    }

    func testSwitchingThreadOpensAtItsLatestMessage() {
        let model = Model(thread(40, tag: "A"))
        open(model)
        model.messages = thread(60, tag: "B")
        settle()
        assertAtBottom("a different thread opens at its latest message")
    }

    func testReopeningOpensAtLatestMessage() {
        let model = Model(thread(40, tag: "A"))
        open(model)
        window.orderOut(nil)
        window = nil
        open(model)
        assertAtBottom("coming back to the tab opens at the latest message")
    }
}
