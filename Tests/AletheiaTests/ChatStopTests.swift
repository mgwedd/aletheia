import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class ChatStopTests: XCTestCase {
    func testStopIsShownOnlyWhileSendingAndOnlyWithAStopHandler() {
        XCTAssertEqual(ChatComposerLayout.trailingControl(isSending: false, canStop: true), .send)
        XCTAssertEqual(ChatComposerLayout.trailingControl(isSending: true, canStop: true), .stop)
        XCTAssertEqual(ChatComposerLayout.trailingControl(isSending: true, canStop: false), .send)
        XCTAssertEqual(ChatComposerLayout.trailingControl(isSending: false, canStop: false), .send)
    }

    func testEscapeStopsOnlyWhileSending() {
        XCTAssertTrue(ChatComposerLayout.escapeStops(isSending: true, canStop: true))
        XCTAssertFalse(ChatComposerLayout.escapeStops(isSending: false, canStop: true))
        XCTAssertFalse(ChatComposerLayout.escapeStops(isSending: true, canStop: false))
    }

    private struct Host: View {
        let isSending: Bool
        let onStop: () -> Void
        @State var messages: [ChatMessage] = []
        var body: some View {
            ChatPaneView(title: "this session", messages: $messages, isSending: isSending, onSend: { _ in }, onStop: onStop)
                .frame(width: 600, height: 500)
        }
    }

    private func findTextView(in view: NSView) -> ThemeTextAreaTextView? {
        if let found = view as? ThemeTextAreaTextView { return found }
        for sub in view.subviews { if let found = findTextView(in: sub) { return found } }
        return nil
    }

    private func escape(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
        )!
    }

    private func pressEscape(isSending: Bool) throws -> Int {
        var stops = 0
        let hosting = NSHostingView(rootView: Host(isSending: isSending, onStop: { stops += 1 }))
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let textView = try XCTUnwrap(findTextView(in: hosting))
        window.makeFirstResponder(textView)
        textView.keyDown(with: escape(in: window))
        return stops
    }

    func testEscapeInTheComposerStopsAGenerationInProgress() throws {
        XCTAssertEqual(try pressEscape(isSending: true), 1)
    }

    func testEscapeDoesNothingWhenIdle() throws {
        XCTAssertEqual(try pressEscape(isSending: false), 0)
    }

    func testBothAskSurfacesWireStop() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views")
        for file in ["SessionDetailView.swift", "PatientChatView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(file), encoding: .utf8)
            let chat = try XCTUnwrap(source.range(of: "ChatPaneView("), file)
            XCTAssertTrue(source[chat.upperBound...].prefix(800).contains("onStop:"), "\(file) must pass onStop to ChatPaneView")
        }
    }
}
