import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class ThemeTextAreaTests: XCTestCase {
    // MARK: Metrics

    func testPlaceholderInsetEqualsTextInset() {
        // Text starts at the container inset plus the container's own padding;
        // that is the design's 12 x 10, and it is where the placeholder goes.
        let origin = ThemeTextAreaMetrics.textOrigin
        XCTAssertEqual(origin.x, ThemeTextAreaMetrics.horizontalPadding)
        XCTAssertEqual(origin.y, ThemeTextAreaMetrics.verticalPadding)
        XCTAssertEqual(ThemeTextAreaMetrics.textContainerInset.width + ThemeTextAreaMetrics.lineFragmentPadding, 12)
    }

    func testSingleLineFieldUsesTheSameInsetAsTheTextArea() {
        XCTAssertEqual(ThemeTextFieldMetrics.horizontalPadding, ThemeTextAreaMetrics.textOrigin.x)
    }

    func testThemeTextFieldHostsAndFitsItsHeight() {
        struct Host: View {
            @State var name = ""
            var body: some View { ThemeTextField(placeholder: "Patient name", text: $name).frame(width: 300) }
        }
        let hosting = NSHostingView(rootView: Host())
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, ThemeTextFieldMetrics.height, accuracy: 1)
    }

    func testBodyAndPlaceholderShareFontAndParagraphStyle() {
        for face in [ThemeTextArea.Face.body, .monospaced] {
            let text = ThemeTextAreaMetrics.attributes(face: face, color: .black)
            let hint = ThemeTextAreaMetrics.attributes(face: face, color: .gray)
            XCTAssertEqual(text[.font] as? NSFont, hint[.font] as? NSFont)
            XCTAssertEqual(
                (text[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing,
                (hint[.paragraphStyle] as? NSParagraphStyle)?.lineSpacing
            )
        }
    }

    // MARK: Real text view

    private func makeTextView(text: String = "", placeholder: String = "Ask about this session…", width: CGFloat = 320) -> (ThemeTextAreaTextView, NSScrollView, NSWindow) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        let textView = ThemeTextAreaTextView(frame: NSRect(x: 0, y: 0, width: width, height: 120))
        textView.minSize = NSSize(width: 0, height: 120)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = ThemeTextAreaMetrics.lineFragmentPadding
        textView.textContainerInset = ThemeTextAreaMetrics.textContainerInset
        textView.isRichText = false
        textView.drawsBackground = false
        scroll.documentView = textView
        scroll.drawsBackground = false
        textView.placeholder = placeholder
        textView.applyStyle()
        textView.string = text
        textView.applyStyle()
        let window = TestWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        return (textView, scroll, window)
    }

    func testPlaceholderOriginIsWhereTheFirstCharacterAndCaretGo() throws {
        let (empty, _, w1) = makeTextView()
        let (typed, _, w2) = makeTextView(text: "A")
        _ = (w1, w2)
        let layout = try XCTUnwrap(typed.layoutManager)
        let container = try XCTUnwrap(typed.textContainer)
        layout.ensureLayout(for: container)
        let firstLine = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let glyph = layout.location(forGlyphAt: 0)
        // The first character's origin in the text view.
        let textStart = NSPoint(
            x: typed.textContainerOrigin.x + firstLine.minX + glyph.x,
            y: typed.textContainerOrigin.y + firstLine.minY
        )
        XCTAssertEqual(empty.placeholderOrigin.x, textStart.x, accuracy: 0.01)
        XCTAssertEqual(empty.placeholderOrigin.y, textStart.y, accuracy: 0.01)
        XCTAssertEqual(empty.placeholderOrigin.x, ThemeTextAreaMetrics.textOrigin.x, accuracy: 0.01)
        XCTAssertEqual(empty.placeholderOrigin.y, ThemeTextAreaMetrics.textOrigin.y, accuracy: 0.01)

        // The caret in the empty field sits on the same point.
        let emptyLayout = try XCTUnwrap(empty.layoutManager)
        let emptyContainer = try XCTUnwrap(empty.textContainer)
        emptyLayout.ensureLayout(for: emptyContainer)
        let extra = emptyLayout.extraLineFragmentRect
        XCTAssertEqual(empty.textContainerOrigin.x + extra.minX + emptyContainer.lineFragmentPadding, empty.placeholderOrigin.x, accuracy: 0.01)
        XCTAssertEqual(empty.textContainerOrigin.y + extra.minY, empty.placeholderOrigin.y, accuracy: 0.01)
    }

    /// The pixels the placeholder draws start where the same string typed would.
    func testPlaceholderInkStartsWhereTypedInkStarts() throws {
        let sample = "Hxllo"
        let (hint, hintScroll, w1) = makeTextView(placeholder: sample)
        let (typed, typedScroll, w2) = makeTextView(text: sample, placeholder: sample)
        _ = (w1, w2)
        let hintBox = try XCTUnwrap(inkBounds(of: hintScroll))
        let typedBox = try XCTUnwrap(inkBounds(of: typedScroll))
        XCTAssertTrue(hint.showsPlaceholder)
        XCTAssertFalse(typed.showsPlaceholder)
        XCTAssertEqual(hintBox.minX, typedBox.minX, accuracy: 1)
        XCTAssertEqual(hintBox.minY, typedBox.minY, accuracy: 1)
        XCTAssertEqual(hintBox.height, typedBox.height, accuracy: 1)
    }

    private func inkBounds(of view: NSView) -> CGRect? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.05 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    // MARK: Keys

    private func keyDown(_ code: UInt16, flags: NSEvent.ModifierFlags = [], in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code
        )!
    }

    func testReturnSubmitsAndShiftOrOptionReturnAddsALine() {
        let (textView, _, window) = makeTextView(text: "hi")
        var sent = 0
        textView.onSubmit = { sent += 1 }
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.keyDown(with: keyDown(36, in: window))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(textView.string, "hi")

        textView.keyDown(with: keyDown(36, flags: .shift, in: window))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(textView.string, "hi\n")

        textView.keyDown(with: keyDown(36, flags: .option, in: window))
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(textView.string, "hi\n\n")
    }

    func testChatStyleFieldSendsOnEveryReturnAndNeverAddsALine() {
        let (textView, _, window) = makeTextView(text: "hi")
        var sent = 0
        textView.onSubmit = { sent += 1 }
        textView.modifiedReturnSubmits = true
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        for (code, flags) in [(UInt16(36), NSEvent.ModifierFlags()), (76, []), (36, .shift), (36, .option), (36, [.shift, .option])] {
            textView.keyDown(with: keyDown(code, flags: flags, in: window))
        }
        XCTAssertEqual(sent, 5)
        XCTAssertEqual(textView.string, "hi")
    }

    func testReturnIsANewlineWhenThereIsNoSubmitHandler() {
        let (textView, _, window) = makeTextView(text: "hi")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.keyDown(with: keyDown(36, in: window))
        XCTAssertEqual(textView.string, "hi\n")
    }

    func testTabTypesATabUnlessFocusMoveIsRequested() {
        let (textView, _, window) = makeTextView(text: "hi")
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.insertTab(nil)
        XCTAssertEqual(textView.string, "hi\t")
    }

    // MARK: Hosted in SwiftUI

    private struct Host: View {
        @State var text = ""
        @State var focused = false
        var body: some View {
            ThemeTextArea(
                text: $text,
                placeholder: "Ask about this session…",
                height: .grows(min: ChatComposerLayout.minFieldHeight, max: ChatComposerLayout.maxFieldHeight),
                onSubmit: {},
                isFocused: $focused
            )
            .frame(width: 320)
        }
    }

    private func findTextView(in view: NSView) -> ThemeTextAreaTextView? {
        if let found = view as? ThemeTextAreaTextView { return found }
        for sub in view.subviews { if let found = findTextView(in: sub) { return found } }
        return nil
    }

    private func hostedWindow() -> (NSHostingView<Host>, NSWindow) {
        let hosting = NSHostingView(rootView: Host())
        let window = TestWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (hosting, window)
    }

    func testHostedFieldDrawsItsPlaceholderAtTheInsetAndGrowsThenScrolls() throws {
        let (hosting, _) = hostedWindow()
        let textView = try XCTUnwrap(findTextView(in: hosting))

        XCTAssertTrue(textView.showsPlaceholder)
        XCTAssertEqual(textView.placeholderOrigin.x, ThemeTextAreaMetrics.textOrigin.x, accuracy: 0.01)
        XCTAssertEqual(textView.placeholderOrigin.y, ThemeTextAreaMetrics.textOrigin.y, accuracy: 0.01)

        // One line is the minimum height; many lines are capped.
        XCTAssertEqual(hosting.fittingSize.height, ChatComposerLayout.minFieldHeight, accuracy: 1)
        textView.string = (1...30).map { "line \($0)" }.joined(separator: "\n")
        textView.didChangeText()
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.fittingSize.height, ChatComposerLayout.maxFieldHeight, accuracy: 1)
    }

    func testTypingHidesThePlaceholder() throws {
        let (hosting, window) = hostedWindow()
        let textView = try XCTUnwrap(findTextView(in: hosting))
        window.makeFirstResponder(textView)
        textView.insertText("hello", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(textView.string, "hello")
        XCTAssertFalse(textView.showsPlaceholder)
    }
}
