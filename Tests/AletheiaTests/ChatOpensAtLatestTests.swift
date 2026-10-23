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
        @Published var isSending = false
        init(_ messages: [ChatMessage]) { self.messages = messages }
    }

    private struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            ChatPaneView(
                title: "this session",
                messages: $model.messages,
                isSending: model.isSending,
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

    /// Streams an answer the way the runners do: a new assistant message whose
    /// text grows chunk by chunk, then sending ends.
    private func stream(into model: Model, chunks: Int, settleEach: Bool = true, check: ((Int) -> Void)? = nil) {
        model.messages.append(ChatMessage(role: .user, text: "Describe the client"))
        model.isSending = true
        settle()
        let id = UUID()
        var text = ""
        model.messages.append(ChatMessage(id: id, role: .assistant, text: text))
        for chunk in 0..<chunks {
            text += "Chunk \(chunk) of the answer, several words long enough to wrap. " + (chunk % 4 == 3 ? "\n\n" : "")
            model.messages[model.messages.count - 1] = ChatMessage(id: id, role: .assistant, text: text)
            if settleEach { settle() }
            check?(chunk)
        }
        model.isSending = false
        settle()
    }

    func testAStreamingAnswerStaysOnTheLatestText() {
        let model = Model(thread(10, tag: "A"))
        open(model)
        stream(into: model, chunks: 40) { chunk in
            if chunk > 10 { self.assertAtBottom("follows the answer as it grows (chunk \(chunk))") }
        }
        assertAtBottom("stays on the latest text when the answer ends")
        settle()
        assertAtBottom("and is still there a moment later")
    }

    func testScrollingUpDuringAnAnswerIsLeftAlone() throws {
        let model = Model(thread(20, tag: "A"))
        open(model)
        let scroll = try XCTUnwrap(chatScrollView())
        model.messages.append(ChatMessage(role: .user, text: "Describe the client"))
        model.isSending = true
        let id = UUID()
        var text = "Start. "
        model.messages.append(ChatMessage(id: id, role: .assistant, text: text))
        settle()
        // The therapist scrolls back into the history.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        for chunk in 0..<20 {
            text += "More of the answer, chunk \(chunk), long enough to wrap the line. "
            model.messages[model.messages.count - 1] = ChatMessage(id: id, role: .assistant, text: text)
            settle()
        }
        model.isSending = false
        settle()
        XCTAssertEqual(scroll.contentView.documentVisibleRect.minY, 200, accuracy: 30, "the reader's place is kept")
    }

    /// A small nudge up, still near the bottom, is the reader taking over too.
    func testANudgeUpDuringAnAnswerStopsFollowing() throws {
        let model = Model(thread(20, tag: "A"))
        open(model)
        let scroll = try XCTUnwrap(chatScrollView())
        let id = UUID()
        var text = "Start. "
        model.messages.append(ChatMessage(role: .user, text: "Describe the client"))
        model.isSending = true
        model.messages.append(ChatMessage(id: id, role: .assistant, text: text))
        settle()
        assertAtBottom("following before the nudge")
        let nudged = scroll.contentView.bounds.origin.y - 15
        scroll.contentView.scroll(to: NSPoint(x: 0, y: nudged))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle()
        for chunk in 0..<10 {
            text += "More of the answer, chunk \(chunk), long enough to wrap the line. "
            model.messages[model.messages.count - 1] = ChatMessage(id: id, role: .assistant, text: text)
            settle()
        }
        XCTAssertEqual(scroll.contentView.bounds.origin.y, nudged, accuracy: 30, "the reader's place is kept")
    }
}
