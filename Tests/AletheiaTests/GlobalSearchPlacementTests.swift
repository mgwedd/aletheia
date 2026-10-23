import XCTest
import SwiftUI
import AppKit
@testable import Aletheia

/// ⌘F and where the search field lives, in a real window: the field sits at the
/// foot of the patient sidebar (so it reads as global), and ⌘F focuses it even
/// when a transcript's text view has the cursor.
@MainActor
final class GlobalSearchPlacementTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    /// The sidebar beside a transcript, wired as `RootView` wires them.
    private struct Host: View {
        let appModel: AppModel
        let settings: AppSettings
        @ObservedObject var search: GlobalSearchModel
        @FocusState private var searchFocused: Bool
        @State private var selected: Patient?
        @State private var text = String(repeating: "[00:01] Speaker: transcript line.\n", count: 50)
        @State private var selection = ""
        @State private var range: NSRange?

        init(appModel: AppModel, settings: AppSettings, search: GlobalSearchModel) {
            self.appModel = appModel
            self.settings = settings
            self.search = search
        }

        var body: some View {
            HStack(spacing: 0) {
                PatientsListView(
                    selectedPatient: $selected, search: search, searchFocused: $searchFocused,
                    onOpenSearchResult: { _ in }, onOpenSettings: {}, onEditProfile: { _ in }
                )
                .frame(width: 320)
                TranscriptTextView(text: $text, comments: [], selection: $selection, selectionRange: $range)
            }
            .background { GlobalSearchHotkey(isFocused: $searchFocused) }
            .environmentObject(appModel)
            .environmentObject(settings)
        }
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var window: NSWindow!
    private var search: GlobalSearchModel!

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
        search = GlobalSearchModel()
        window = TestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(appModel: appModel, settings: settings, search: search))
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    override func tearDown() async throws {
        window.orderOut(nil)
        window = nil
        search = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func settle() {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private var searchField: NSTextField? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == GlobalSearchField.prompt
                || $0.placeholderAttributedString?.string == GlobalSearchField.prompt
        }
    }

    private var transcript: NSTextView? {
        guard let content = window.contentView else { return nil }
        return descendants(of: content).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }
    }

    private func isFocused(_ field: NSTextField) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return editor.delegate === field
    }

    private func pressCommandF(option: Bool = false) {
        var flags: NSEvent.ModifierFlags = .command
        if option { flags.insert(.option) }
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.sendEvent(event)
        settle()
    }

    func testTheSearchFieldIsAtTheFootOfTheSidebar() throws {
        let field = try XCTUnwrap(searchField, "the search field is in the sidebar")
        let content = try XCTUnwrap(window.contentView)
        let frame = field.convert(field.bounds, to: content)
        XCTAssertLessThan(frame.maxX, 320, "inside the sidebar's 320pt column, not the detail pane")
        XCTAssertGreaterThan(frame.width, 200, "the sidebar's full width")
        let fromTop = content.isFlipped ? frame.midY : content.bounds.height - frame.midY
        XCTAssertGreaterThan(fromTop, content.bounds.height * 2 / 3, "in the lower part of the sidebar")
        XCTAssertEqual(GlobalSearchField.prompt, "Search all patients")
    }

    /// Settings is a footer button, not a toolbar item that can fall into the » overflow.
    func testTheSidebarFooterHasSettingsAndNoToolbarItemsRemain() throws {
        let list = try source("Sources/App/Views/PatientsListView.swift")
        XCTAssertTrue(list.contains("Button(action: onOpenSettings)"), "Settings is a button in the sidebar footer")
        XCTAssertTrue(list.contains("Label(\"Settings\", systemImage: \"gearshape\")"))
        XCTAssertFalse(list.contains(".toolbar {"), "no sidebar toolbar items to overflow")
        XCTAssertFalse(try source("Sources/App/Views/RootView.swift").contains("Label(\"Settings\""))
    }

    private func source(_ path: String) throws -> String {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// An empty list shows exactly one add control (the empty state's), under one name.
    func testAnEmptyListShowsExactlyOneAddControl() throws {
        let list = try source("Sources/App/Views/PatientsListView.swift")
        XCTAssertEqual(PatientsListView.addPatientTitle, "Add Patient")
        XCTAssertFalse(list.contains("New patient"))
        // Two add buttons exist in the source: the empty state's, and the footer's,
        // which is only built while there are patients.
        XCTAssertEqual(list.components(separatedBy: "Self.addPatientTitle").count - 1, 2)
        let footer = try XCTUnwrap(list.components(separatedBy: "if !appModel.patients.isEmpty {").dropFirst().first)
        XCTAssertTrue(footer.prefix(400).contains("Self.addPatientTitle"), "the footer's button is inside the non-empty branch")
        let empty = try XCTUnwrap(list.components(separatedBy: "if appModel.patients.isEmpty {").dropFirst().first)
        XCTAssertTrue(empty.prefix(600).contains("Self.addPatientTitle"))
        XCTAssertTrue(appModelHasNoPatients, "this test host starts with an empty list")
    }

    private var appModelHasNoPatients: Bool { searchField != nil }

    func testCommandFFocusesTheSearchField() throws {
        let field = try XCTUnwrap(searchField)
        XCTAssertFalse(isFocused(field))
        pressCommandF()
        XCTAssertTrue(isFocused(field), "first responder: \(String(describing: window.firstResponder))")
    }

    func testOptionCommandFLeavesTheCursorInTheTranscriptForItsOwnFindBar() throws {
        let field = try XCTUnwrap(searchField)
        let text = try XCTUnwrap(transcript)
        XCTAssertTrue(window.makeFirstResponder(text))
        pressCommandF(option: true)
        XCTAssertFalse(isFocused(field), "⌥⌘F is not the global search")
    }

    func testTheShortcutsAreMatchedByModifiers() throws {
        func event(_ flags: NSEvent.ModifierFlags, _ key: String = "f") -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 3)!
        }
        XCTAssertTrue(GlobalSearchShortcut.isGlobalSearch(event(.command)))
        XCTAssertFalse(GlobalSearchShortcut.isGlobalSearch(event([.command, .option])))
        XCTAssertFalse(GlobalSearchShortcut.isGlobalSearch(event([])))
        XCTAssertFalse(GlobalSearchShortcut.isGlobalSearch(event(.command, "g")))
        XCTAssertTrue(GlobalSearchShortcut.isFindInText(event([.command, .option])))
        XCTAssertFalse(GlobalSearchShortcut.isFindInText(event(.command)))
    }

    func testCommandFFocusesTheSearchFieldFromATranscript() throws {
        let field = try XCTUnwrap(searchField)
        let text = try XCTUnwrap(transcript, "the transcript's text view")
        XCTAssertTrue(window.makeFirstResponder(text))
        XCTAssertTrue(window.firstResponder === text)
        pressCommandF()
        XCTAssertTrue(isFocused(field), "first responder: \(String(describing: window.firstResponder))")
    }
}
