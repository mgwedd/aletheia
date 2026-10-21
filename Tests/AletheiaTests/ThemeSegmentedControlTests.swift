import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class ThemeSegmentedControlTests: XCTestCase {
    private func control(_ titles: [String], sizing: ThemeSegmentedControl<String>.Sizing) -> some View {
        ThemeSegmentedControl(
            options: titles.map { ThemeTab(value: $0, title: $0) },
            selection: .constant(titles[0]),
            sizing: sizing
        )
    }

    private func width<V: View>(_ view: V, offered: CGFloat = 2_000) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: offered, height: 200)).width
    }

    private func labelWidth(_ title: String) -> CGFloat {
        width(Text(title).font(Theme.Typography.control).lineLimit(1).fixedSize())
    }

    private let notes = NotesPane.all.map(\.label)

    /// Fitted takes only what its labels need, whatever it is offered.
    func testFittedDoesNotStretchToTheOfferedWidth() {
        let wide = width(control(notes, sizing: .fitted), offered: 2_000)
        XCTAssertEqual(wide, width(control(notes, sizing: .fitted), offered: 1_200), accuracy: 1)
        XCTAssertLessThan(wide, 1_200)
    }

    /// Each segment is its label plus the same padding, so a longer label adds
    /// only its own extra width (equal widths would add it once per segment).
    func testALongerLabelAddsOnlyItsOwnExtraWidth() {
        let short = width(control(["DAP", "DAP", "DAP"], sizing: .fitted))
        let mixed = width(control(["DAP", "DAP", "My Notes"], sizing: .fitted))
        XCTAssertEqual(mixed - short, labelWidth("My Notes") - labelWidth("DAP"), accuracy: 2)
    }

    /// Total width is the labels, plus even padding around each, plus the
    /// fixed spacing and track inset.
    func testEverySegmentGetsTheSamePadding() {
        let padding = ThemeSegmentedControl<String>.labelPadding
        let labels = notes.map(labelWidth).reduce(0, +)
        let expected = labels
            + CGFloat(notes.count) * 2 * padding
            + CGFloat(notes.count - 1) * 2  // spacing between segments
            + 6  // track inset on both sides
        XCTAssertEqual(width(control(notes, sizing: .fitted)), expected, accuracy: 2)
    }

    /// The default is unchanged: equal segments fill what they are given.
    func testEqualStillFillsTheOfferedWidth() {
        XCTAssertEqual(width(control(notes, sizing: .equal), offered: 900), 900, accuracy: 1)
    }
}
