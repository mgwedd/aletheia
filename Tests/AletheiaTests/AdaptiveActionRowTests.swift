import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

@MainActor
final class AdaptiveActionRowTests: XCTestCase {
    private let caption = "Plain-prose summary of the session, no fixed headings — Aletheia's default."

    @ViewBuilder private var buttons: some View {
        Button {} label: { Label("Regenerate", systemImage: "sparkles") }
        Menu {} label: { AdaptiveLabel(title: "Length: Concise · Fast", systemImage: "text.alignleft") }
            .fixedSize()
        Button {} label: { Label("Edit", systemImage: "pencil") }
        Button {} label: { Label("Copy", systemImage: "doc.on.doc") }
        Button {} label: { Label("Export", systemImage: "square.and.arrow.up") }
    }

    private var oldRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            buttons
        }
        .buttonStyle(.themed)
    }

    private var newRow: some View {
        AdaptiveActionRow {
            Text(self.caption).fixedSize(horizontal: false, vertical: true)
        } actions: {
            self.buttons
        }
        .buttonStyle(.themed)
    }

    private func size<V: View>(_ view: V, width: CGFloat) -> CGSize {
        NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: width, height: 10_000))
    }

    /// The premise: the old row asks for more width than a narrow pane has,
    /// which is what widened the column and pushed the toolbar off the window.
    func testTheOldRowAsksForMoreWidthThanANarrowPaneHas() {
        XCTAssertGreaterThan(size(oldRow, width: 360).width, 361)
    }

    func testTheRowNeverAsksForMoreWidthThanItIsGiven() {
        for width: CGFloat in [1_400, 900, 600, 420, 360] {
            XCTAssertLessThanOrEqual(size(newRow, width: width).width, width + 1, "at \(width) pt")
        }
    }

    /// Wide: one line, as before. Narrow: stacked, so it grows taller.
    func testItStaysOnOneLineWhenThereIsRoomAndStacksWhenThereIsNot() {
        let wide = size(newRow, width: 1_400).height
        let narrow = size(newRow, width: 420).height
        XCTAssertGreaterThan(narrow, wide + 10)
    }

    /// The caption gets its own line rather than a word per line.
    func testTheCaptionIsNotSqueezedIntoAColumn() {
        let narrow = size(newRow, width: 420).height
        XCTAssertLessThan(narrow, 200, "a squeezed caption makes the row hundreds of points tall")
    }

    func testAdaptiveLabelShowsOnlyItsIconInTheCompactArrangement() {
        let full = NSHostingView(rootView: AdaptiveLabel(title: "Length: Concise · Fast", systemImage: "text.alignleft"))
        let compact = NSHostingView(rootView: AdaptiveLabel(title: "Length: Concise · Fast", systemImage: "text.alignleft")
            .environment(\.compactActions, true))
        XCTAssertLessThan(compact.fittingSize.width, full.fittingSize.width / 2)
    }

    /// The Notes tab uses it, so its buttons adapt there. The format blurb is
    /// a hover tip on the format picker now, not the row's caption.
    func testTheNotesTabActionRowIsAdaptive() throws {
        let source = try String(contentsOf: Self.source("SessionDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("AdaptiveActionRow {\n                    EmptyView()\n                } actions: {"))
        XCTAssertFalse(source.contains("Text(settings.progressNoteFormat.blurb)"))
        XCTAssertTrue(source.contains(".hoverTip(showingMyNotes ? HelpTips.myNotes : HelpTips.noteFormat(settings.progressNoteFormat))"))
        XCTAssertTrue(source.contains("AdaptiveLabel(\n                title: \"Length:"),
                      "the Length menu label should compact with the row")
    }

    /// Keyboard focus starts on Export, not on the first format row.
    func testTheExportPopoverFocusesTheExportButton() throws {
        let source = try String(contentsOf: Self.source("ExportButton.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".focused($exportFocused)"))
        XCTAssertTrue(source.contains(".defaultFocus($exportFocused, true)"))
    }

    private static func source(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/\(name)")
    }
}
