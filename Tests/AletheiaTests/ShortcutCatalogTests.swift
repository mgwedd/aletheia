import XCTest
import SwiftUI
@testable import Aletheia

final class ShortcutCatalogTests: XCTestCase {
    private var allEntries: [ShortcutEntry] { ShortcutCatalog.sections.flatMap(\.entries) }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    func testEverySectionAndEntryIsNamed() {
        XCTAssertFalse(ShortcutCatalog.sections.isEmpty)
        for section in ShortcutCatalog.sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.entries.isEmpty, section.title)
        }
        XCTAssertTrue(allEntries.allSatisfy { !$0.title.isEmpty })
    }

    func testNoTwoEntriesShareAKeyOrATitle() {
        let keys = allEntries.map { ShortcutGlyphs.symbols(for: $0.shortcut) }
        XCTAssertEqual(Set(keys).count, keys.count, "two rows would show the same keys: \(keys)")
        let titles = allEntries.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
    }

    func testEveryAppHotkeyIsListed() {
        let listed = Set(allEntries.map { ShortcutGlyphs.symbols(for: $0.shortcut) })
        let defined: [KeyboardShortcut] = [
            AppHotkey.search, AppHotkey.newPatient, AppHotkey.closeWindow, AppHotkey.showShortcuts, AppHotkey.saveComment,
            AppHotkey.saveEdits, AppHotkey.generateNote, AppHotkey.bold, AppHotkey.italic,
            AppHotkey.bulletedList, AppHotkey.numberedList, AppHotkey.bodyText, AppHotkey.heading,
            AppHotkey.subheading,
        ]
        for shortcut in defined {
            XCTAssertTrue(listed.contains(ShortcutGlyphs.symbols(for: shortcut)), ShortcutGlyphs.symbols(for: shortcut))
        }
    }

    func testTheCatalogReadsAsMacKeys() {
        let symbols = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.title, ShortcutGlyphs.symbols(for: $0.shortcut)) })
        XCTAssertEqual(symbols["Add Patient"], "⌘N")
        XCTAssertEqual(symbols["Bulleted list"], "⇧⌘7")
        XCTAssertEqual(symbols["Heading"], "⇧⌘H")
        XCTAssertEqual(symbols["Save a comment"], "⌘↩")
        XCTAssertEqual(symbols["Close a sheet or search"], "esc")
        XCTAssertEqual(symbols["Keyboard shortcuts"], "⌘/")
    }

    // MARK: The listed keys are the bound keys

    func testTheRegistryListsSaveAndGenerate() throws {
        let byTitle = Dictionary(uniqueKeysWithValues: allEntries.map { ($0.title, $0.shortcut) })
        XCTAssertEqual(try XCTUnwrap(byTitle["Save your edits"]).key, AppHotkey.saveEdits.key)
        XCTAssertEqual(try XCTUnwrap(byTitle["Generate or regenerate the note"]).key, AppHotkey.generateNote.key)
        XCTAssertEqual(ShortcutGlyphs.keys(for: AppHotkey.saveEdits), ["⌘", "S"])
        XCTAssertEqual(ShortcutGlyphs.keys(for: AppHotkey.generateNote), ["⌘", "G"])
    }

    func testSaveAndGenerateBindThroughTheRegistryNotLiterals() throws {
        let session = try source("Sources/App/Views/SessionDetailView.swift")
        let profile = try source("Sources/App/Views/PatientProfileEditor.swift")
        for (name, text) in [("SessionDetailView", session), ("PatientProfileEditor", profile)] {
            XCTAssertFalse(text.contains(".keyboardShortcut(\"s\""), "\(name) binds a literal Command-S")
            XCTAssertFalse(text.contains(".keyboardShortcut(\"g\""), "\(name) binds a literal Command-G")
        }
        XCTAssertTrue(session.contains(".shortcut(AppHotkey.saveEdits"))
        XCTAssertTrue(session.contains(".shortcut(AppHotkey.generateNote"))
        XCTAssertTrue(profile.contains(".keyboardShortcut(AppHotkey.saveEdits)"))
    }

    func testHintsInsideFilledButtonsUseTheOnAccentCap() throws {
        let session = try source("Sources/App/Views/SessionDetailView.swift")
        XCTAssertTrue(session.contains("ShortcutHint(AppHotkey.generateNote, onAccent: true)"))
        let components = try source("Sources/App/Views/Theme/ThemeComponents.swift")
        XCTAssertTrue(components.contains("Theme.accentKeyCap"))
        XCTAssertTrue(components.contains("Theme.accentInk"))
    }

    func testTheOnAccentCapIsAContrastPairing() {
        XCTAssertTrue(Theme.all.contains(Theme.accentKeyCap))
        XCTAssertTrue(Theme.pairings.contains {
            $0.foreground == Theme.accentInk && $0.background == Theme.accentKeyCap && $0.minimum >= 4.5
        })
    }

    func testTheAppMenusBindThroughTheDefinitions() throws {
        let app = try source("Sources/App/AletheiaApp.swift")
        XCTAssertTrue(app.contains(".keyboardShortcut(AppHotkey.closeWindow)"))
        XCTAssertTrue(app.contains(".keyboardShortcut(AppHotkey.showShortcuts)"))
        XCTAssertTrue(app.contains("Window(\"Keyboard Shortcuts\", id: ShortcutsWindow.id)"))
        XCTAssertTrue(app.contains("openWindow(id: ShortcutsWindow.id)"))
    }

    func testTheNoteEditorsTextViewHandlesTheListedKeys() throws {
        let editor = try source("Sources/App/Views/RichNoteEditor.swift")
        for shortcut in [AppHotkey.bold, AppHotkey.italic, AppHotkey.bodyText, AppHotkey.heading, AppHotkey.subheading] {
            XCTAssertTrue(editor.contains("key == \"\(shortcut.key.character)\""), String(shortcut.key.character))
        }
        // Shift changes the digit's character, so the lists match on key codes (7 is 26, 9 is 25).
        XCTAssertEqual(AppHotkey.bulletedList.key.character, "7")
        XCTAssertEqual(AppHotkey.numberedList.key.character, "9")
        XCTAssertTrue(editor.contains("event.keyCode == 26"))
        XCTAssertTrue(editor.contains("event.keyCode == 25"))
    }

    func testTheShortcutsWindowHasItsOwnID() {
        XCTAssertEqual(ShortcutsWindow.id, "shortcuts")
        let others = [MainWindow.id, DoctorFeatureModule.windowID, PatientChatWindow.windowID]
        XCTAssertFalse(others.contains(ShortcutsWindow.id))
    }
}
