import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// With no patient open, ⌘F goes to the search home's large field rather than
/// the small one at the foot of the sidebar.
@MainActor
final class SearchHomeHotkeyTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    /// The sidebar beside the search home, wired as `RootView` wires them.
    private struct Host: View {
        let appModel: AppModel
        let settings: AppSettings
        @StateObject private var search = GlobalSearchModel()
        @FocusState private var sidebarFocused: Bool
        @FocusState private var homeFocused: Bool
        @State private var selected: Patient?

        var body: some View {
            HStack(spacing: 0) {
                PatientsListView(
                    selectedPatient: $selected, search: search, searchFocused: $sidebarFocused,
                    onOpenSearchResult: { _ in }, onOpenSettings: {}, onEditProfile: { _ in }
                )
                .frame(width: 320)
                SearchHomeView(model: search, onOpen: { _ in }, isFocused: $homeFocused)
            }
            .background { GlobalSearchHotkey(isFocused: $homeFocused) }
            .environmentObject(appModel)
            .environmentObject(settings)
        }
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var window: NSWindow!

    override func setUp() async throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        originalDataRoot = settings.dataRootURL
        settings.dataRootURL = tempRoot
        let root = tempRoot!
        let appModel = AppModel(
            settings: settings, encryption: EncryptionManager(dataRootProvider: { root }),
            spotlightIndexer: NoopSpotlightIndexer())
        window = TestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(appModel: appModel, settings: settings))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        SessionSearch.index = SearchIndex()   // AppModel pointed it at this test's folder
        window.orderOut(nil)
        window = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    /// Runs the loop until `condition` holds, or a second passes.
    private func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func field(_ prompt: String) -> NSTextField? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == prompt || $0.placeholderAttributedString?.string == prompt
        }
    }

    private func isFocused(_ field: NSTextField) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate === field
    }

    private func pressCommandF() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.sendEvent(event)
        settle()
    }

    func testCommandFMovesTheCursorFromTheSidebarToTheHomeField() throws {
        // SwiftUI only moves focus in the key window, and a window is only key
        // while the app is frontmost, which a full run in the background isn't.
        try XCTSkipIf(TestHost.runsInBackground(), "the test host runs in the background; CI runs this in the foreground")
        try XCTSkipUnless(window.isKeyWindow, "the test window can't become key while another app is frontmost")
        let sidebar = try XCTUnwrap(field(GlobalSearchField.prompt))
        let home = try XCTUnwrap(field(GlobalSearchField.homePrompt))
        // The home focuses its field once it appears; let that land first, or it
        // takes the cursor back from the sidebar as a click that early would lose it.
        wait { isFocused(home) }
        XCTAssertTrue(isFocused(home))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        settle()
        XCTAssertTrue(isFocused(sidebar), "first responder: \(String(describing: window.firstResponder)), home has it: \(isFocused(home))")
        pressCommandF()
        XCTAssertTrue(isFocused(home), "first responder: \(String(describing: window.firstResponder))")
        XCTAssertFalse(isFocused(sidebar))
    }

    /// The root hands ⌘F to the home field only while no patient is open.
    func testTheRootPicksTheHomeFieldOnlyWithNoPatientOpen() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = try String(contentsOf: repo.appendingPathComponent("Sources/App/Views/RootView.swift"), encoding: .utf8)
        XCTAssertTrue(root.contains("isFocused: hasOpenPatient ? $searchFocused : $homeSearchFocused"))
        XCTAssertTrue(root.contains("isFocused: $homeSearchFocused"), "the search home is bound to the same state")
    }
}
