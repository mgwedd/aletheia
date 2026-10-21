import XCTest
import SwiftUI
@testable import Aletheia

final class ShortcutGlyphsTests: XCTestCase {
    func testModifiersPrintInMacMenuOrderBeforeTheKey() {
        let all = KeyboardShortcut("m", modifiers: [.command, .shift, .option, .control])
        XCTAssertEqual(ShortcutGlyphs.keys(for: all), ["⌃", "⌥", "⇧", "⌘", "M"])
        XCTAssertEqual(ShortcutGlyphs.keys(for: KeyboardShortcut("m", modifiers: [.command, .option])), ["⌥", "⌘", "M"])
    }

    func testLettersAreUppercasedAndABareKeyHasNoModifiers() {
        XCTAssertEqual(ShortcutGlyphs.keys(for: KeyboardShortcut("n", modifiers: .command)), ["⌘", "N"])
        XCTAssertEqual(ShortcutGlyphs.keys(for: KeyboardShortcut("k", modifiers: [])), ["K"])
    }

    func testSpecialKeysUseTheirGlyphs() {
        let expected: [(KeyEquivalent, String)] = [
            (.return, "↩"), (.escape, "esc"), (.tab, "⇥"), (.space, "Space"), (.delete, "⌫"),
            (.upArrow, "↑"), (.downArrow, "↓"), (.leftArrow, "←"), (.rightArrow, "→"),
        ]
        for (key, glyph) in expected {
            XCTAssertEqual(ShortcutGlyphs.keys(for: KeyboardShortcut(key, modifiers: [])), [glyph])
        }
    }

    func testSwiftUIsOwnDefaultAndCancelActionsReadAsReturnAndEscape() {
        XCTAssertEqual(ShortcutGlyphs.keys(for: .defaultAction), ["↩"])
        XCTAssertEqual(ShortcutGlyphs.keys(for: .cancelAction), ["esc"])
    }

    func testSymbolsRunTheKeysTogether() {
        XCTAssertEqual(ShortcutGlyphs.symbols(for: AppShortcut.newPatient), "⌘N")
        XCTAssertEqual(ShortcutGlyphs.symbols(for: AppShortcut.saveComment), "⌘↩")
    }

    func testSpokenNamesSpellOutEveryKey() {
        XCTAssertEqual(ShortcutGlyphs.spoken(for: KeyboardShortcut("m", modifiers: [.command, .option])), "Option Command M")
        XCTAssertEqual(ShortcutGlyphs.spoken(for: AppShortcut.saveComment), "Command Return")
        XCTAssertEqual(ShortcutGlyphs.spoken(for: .cancelAction), "Escape")
    }

    func testHelpAppendsTheShortcutToTheTooltip() {
        XCTAssertEqual(ShortcutGlyphs.help("Add a new patient", AppShortcut.newPatient), "Add a new patient (⌘N)")
        XCTAssertEqual(ShortcutGlyphs.help("Close", .cancelAction), "Close (esc)")
    }
}

/// Hints come from the bound shortcut. A hand-typed glyph next to a binding can
/// drift from it, so this keeps new ones from creeping back in.
final class ShortcutHintWiringTests: XCTestCase {
    private func sourceFiles() throws -> [(name: String, text: String)] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return files
    }

    private let modifierGlyphs = ["⌘", "⌥", "⇧", "⌃"]

    func testTooltipsInFilesThatBindShortcutsDontTypeTheKeysByHand() throws {
        var offenders: [String] = []
        for file in try sourceFiles() where file.text.contains(".keyboardShortcut(") || file.text.contains(".shortcut(") {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() where line.contains(".help(\"") {
                if modifierGlyphs.contains(where: { line.contains($0) }) || line.contains("Command-") {
                    offenders.append("\(file.name):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use .shortcut(_:help:) so the tooltip is built from the binding")
    }

    func testKeyCapsDontSpellModifiersByHand() throws {
        var offenders: [String] = []
        for file in try sourceFiles() {
            for (index, line) in file.text.components(separatedBy: "\n").enumerated() where line.contains("KeyCap(\"") {
                if modifierGlyphs.contains(where: { line.contains($0) }) {
                    offenders.append("\(file.name):\(index + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "use ShortcutHint(_:) so the key caps come from the binding")
    }

    func testTheAppShortcutsAreBoundThroughTheHelper() throws {
        let all = try sourceFiles().map(\.text).joined(separator: "\n")
        XCTAssertTrue(all.contains(".shortcut(AppShortcut.newPatient"))
        XCTAssertTrue(all.contains(".shortcut(AppShortcut.saveComment"))
        XCTAssertTrue(all.contains("ShortcutHint(AppShortcut.saveComment)"))
    }
}
