import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class ReturnKeyActivationTests: XCTestCase {
    final class Model: ObservableObject { @Published var presses = 0 }

    private struct Host: View {
        @ObservedObject var model: Model
        @FocusState var buttonFocused: Bool
        @FocusState var fieldFocused: Bool
        @State private var text = ""
        let focusField: Bool
        var body: some View {
            VStack {
                TextField("field", text: $text).focused($fieldFocused)
                Button("Go") { model.presses += 1 }
                    .buttonStyle(.themed).focused($buttonFocused)
            }
            .frame(width: 300, height: 200)
            .onAppear { if focusField { fieldFocused = true } else { buttonFocused = true } }
        }
    }

    private var window: NSWindow!
    private let model = Model()

    private func makeWindow(focusField: Bool) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model, focusField: focusField))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if focusField, let field = firstTextField(in: window.contentView!) {
            window.makeFirstResponder(field)   // as a click would: the field editor takes over
        }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        for sub in view.subviews { if let f = firstTextField(in: sub) { return f } }
        return nil
    }

    /// A button only takes keyboard focus when "Keyboard navigation" is on in
    /// System Settings; CI runners have it off, so there is nothing to press.
    private func requireFocusedButton() throws {
        try XCTSkipUnless(
            ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: false, responder: window.firstResponder),
            "keyboard navigation is off on this Mac, so no button can take focus")
    }

    override func tearDown() async throws {
        window?.orderOut(nil)
        window = nil
    }

    private func key(_ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func send(_ event: NSEvent) {
        window.sendEvent(ReturnKeyActivation.translated(event))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    func testReturnDoesNothingToAFocusedButtonWithoutTheTranslation() throws {
        makeWindow(focusField: false)
        try requireFocusedButton()
        window.sendEvent(key(36, "\r"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(model.presses, 0, "documents the platform behaviour this fix works around")
    }

    func testReturnPressesTheFocusedButton() throws {
        makeWindow(focusField: false)
        try requireFocusedButton()
        send(key(36, "\r"))
        XCTAssertEqual(model.presses, 1)
    }

    func testKeypadEnterPressesTheFocusedButton() throws {
        makeWindow(focusField: false)
        try requireFocusedButton()
        send(key(76, "\u{3}"))
        XCTAssertEqual(model.presses, 1)
    }

    func testReturnInATextFieldIsLeftAlone() {
        makeWindow(focusField: true)
        let event = key(36, "\r")
        XCTAssertTrue(window.firstResponder is NSTextView, "the field editor owns the keyboard")
        XCTAssertTrue(ReturnKeyActivation.translated(event) === event)
        send(event)
        XCTAssertEqual(model.presses, 0)
    }

    func testDecision() {
        let proxy = NSResponder()   // not a key-view proxy
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: false, responder: proxy))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: false, responder: nil))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: false, responder: NSTextView()))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 0, modifiers: [], isRepeat: false, responder: proxy))
    }

    func testModifiedAndRepeatedReturnsAreLeftAlone() throws {
        makeWindow(focusField: false)
        try requireFocusedButton()
        let responder = window.firstResponder
        XCTAssertTrue(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: false, responder: responder))
        XCTAssertTrue(ReturnKeyActivation.shouldActivate(keyCode: 76, modifiers: .numericPad, isRepeat: false, responder: responder))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: .command, isRepeat: false, responder: responder))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: .shift, isRepeat: false, responder: responder))
        XCTAssertFalse(ReturnKeyActivation.shouldActivate(keyCode: 36, modifiers: [], isRepeat: true, responder: responder))
    }
}
