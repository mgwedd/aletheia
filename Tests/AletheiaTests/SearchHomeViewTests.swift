import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// With no patient open the detail pane is a search home: a large field on the
/// shared search model, filling the whole pane.
@MainActor
final class SearchHomeViewTests: XCTestCase {
    private final class Probe: ObservableObject {
        @Published var size = CGSize.zero
    }

    private struct Host: View {
        @ObservedObject var model: GlobalSearchModel
        @ObservedObject var probe: Probe
        var body: some View {
            SearchHomeView(model: model, onOpen: { _ in })
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { probe.size = proxy.size }.onChange(of: proxy.size) { _, size in probe.size = size }
                })
        }
    }

    private let paneSize = NSSize(width: 800, height: 600)
    private var model: GlobalSearchModel!
    private var probe: Probe!
    private var window: NSWindow!

    override func setUp() async throws {
        model = GlobalSearchModel()
        probe = Probe()
        window = NSWindow(contentRect: NSRect(origin: .zero, size: paneSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(model: model, probe: probe))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private var field: NSTextField? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSTextField }.first {
            $0.placeholderAttributedString?.string == GlobalSearchField.homePrompt
                || $0.placeholderString == GlobalSearchField.homePrompt
        }
    }

    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheEmptyStateHostsTheSearchField() {
        XCTAssertNotNil(field)
    }

    func testTheEmptyStateFillsTheWholePane() throws {
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(probe.size.width, content.bounds.width, accuracy: 0.5)
        XCTAssertEqual(probe.size.height, content.bounds.height, accuracy: 0.5)
        XCTAssertGreaterThan(probe.size.height, 0)
    }

    func testTypingInTheEmptyStateUpdatesTheSharedModel() throws {
        let field = try XCTUnwrap(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.insertText("jane", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
        XCTAssertEqual(model.query, "jane")
        XCTAssertNotNil(self.field, "the field stays (and keeps the cursor) while results show")
        XCTAssertTrue(window.firstResponder === editor)
    }

    func testTheEmptyStateFocusesTheFieldOnAppear() throws {
        let field = try XCTUnwrap(field)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        let editor = window.firstResponder as? NSTextView
        XCTAssertTrue(editor?.isFieldEditor == true && editor?.delegate === field, "first responder: \(String(describing: window.firstResponder))")
    }

    func testTheSelectAPatientCardIsGone() throws {
        let root = try source("Sources/App/Views/RootView.swift")
        XCTAssertFalse(root.contains("Select a Patient"))
        XCTAssertFalse(root.contains("ContentUnavailableView"))
        XCTAssertTrue(root.contains("SearchHomeView("))
    }

    /// The field is enough; the patients are in plain sight on the left.
    func testNoHintUnderTheField() throws {
        XCTAssertFalse(try source("Sources/App/Views/SearchHomeView.swift").contains("on the left"))
    }
}
