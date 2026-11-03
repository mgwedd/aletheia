import SwiftUI
import XCTest
@testable import Aletheia

/// Measuring an answer's height must not disturb the text view that shows it.
/// Synthetic text only.
@MainActor
final class TextMeasureTests: XCTestCase {
    private let look = AnswerText.Look(size: 15, lineSpacing: 0, blockSpacing: 8, listSpacing: 4, ink: Theme.text)
    private let sentence = "She described sleeping badly most nights since the move, waking at three and lying awake. "

    private func measure(_ text: String) -> TextMeasure {
        let measure = TextMeasure()
        measure.storage.setAttributedString(NSAttributedString(
            string: text, attributes: [.font: NSFont.systemFont(ofSize: 15)]))
        return measure
    }

    func testNarrowerWidthIsTaller() {
        let measure = measure(String(repeating: sentence, count: 6))
        let wide = measure.height(atWidth: 700)
        let narrow = measure.height(atWidth: 140)
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide)
    }

    func testAskingAgainAtTheSameWidthGivesTheSameHeight() {
        let measure = measure(String(repeating: sentence, count: 6))
        let first = measure.height(atWidth: 400)
        _ = measure.height(atWidth: 90)
        _ = measure.height(atWidth: 900)
        XCTAssertEqual(measure.height(atWidth: 400), first)
    }

    func testShortTextIsOneLineAtAnyReasonableWidth() {
        let measure = measure("Fine.")
        XCTAssertEqual(measure.height(atWidth: 200), measure.height(atWidth: 900))
    }

    func testHeightIsAWholeNumberOfPoints() {
        let height = measure(String(repeating: sentence, count: 3)).height(atWidth: 333)
        XCTAssertEqual(height, height.rounded(.up))
    }

    func testMeasuringLeavesAnotherTextViewsContainerAlone() {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        view.string = String(repeating: sentence, count: 4)
        let container = try! XCTUnwrap(view.textContainer)
        let before = container.size
        let measure = measure(view.string)
        _ = measure.height(atWidth: 120)
        _ = measure.height(atWidth: 800)
        XCTAssertEqual(container.size, before)
    }

    // MARK: - The answer view

    private func textView(in view: NSView) -> AnswerNSTextView? {
        if let found = view as? AnswerNSTextView { return found }
        for child in view.subviews { if let found = textView(in: child) { return found } }
        return nil
    }

    /// SwiftUI asks the answer for its size at widths it then doesn't use. The
    /// text view's own layout width must stay the width it is shown at.
    func testAskingForSizesDoesNotChangeTheShownTextsWidth() throws {
        let blocks = MarkdownParser.parse(String(repeating: sentence, count: 8))
        let host = NSHostingView(rootView: AnswerTextView(blocks: blocks, look: look))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        host.layoutSubtreeIfNeeded()

        let shown = try XCTUnwrap(textView(in: host), "the answer's text view is in the hosting view")
        let container = try XCTUnwrap(shown.textContainer)
        XCTAssertEqual(container.size.width, shown.frame.width, accuracy: 0.5, "laid out at the width it is shown at")

        // The probes SwiftUI makes: the ideal size, then sizes at other widths.
        _ = host.fittingSize
        host.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        XCTAssertEqual(shown.frame.width, container.size.width, accuracy: 0.5, "text wraps at the frame, not at a probed width")
        XCTAssertFalse(shown.string.isEmpty)
    }

    func testNarrowThenWideLaysTheShownTextOutAtTheWideWidth() throws {
        let blocks = MarkdownParser.parse(String(repeating: sentence, count: 8))
        let host = NSHostingView(rootView: AnswerTextView(blocks: blocks, look: look))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 160, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
        host.layoutSubtreeIfNeeded()
        let shown = try XCTUnwrap(textView(in: host))
        let container = try XCTUnwrap(shown.textContainer)
        XCTAssertEqual(container.size.width, shown.frame.width, accuracy: 0.5)

        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize
        XCTAssertEqual(container.size.width, shown.frame.width, accuracy: 0.5)
        XCTAssertGreaterThan(shown.frame.width, 400)
    }
}
