import SwiftUI

/// How a `KeyboardShortcut` reads on screen, derived from the shortcut itself so
/// a hint can never drift from the key that's actually bound. Pure: no views, so
/// it is unit-tested directly.
enum ShortcutGlyphs {
    /// One entry per key cap, in the order macOS menus print them: ⌃ ⌥ ⇧ ⌘, then
    /// the key. `⌥⌘M` gives `["⌥", "⌘", "M"]`.
    static func keys(for shortcut: KeyboardShortcut) -> [String] {
        modifiers(in: shortcut.modifiers).map(\.glyph) + [key(shortcut.key).glyph]
    }

    /// The caps run together: `⌥⌘M`. For tooltips.
    static func symbols(for shortcut: KeyboardShortcut) -> String {
        keys(for: shortcut).joined()
    }

    /// What VoiceOver should say: "Option Command M".
    static func spoken(for shortcut: KeyboardShortcut) -> String {
        (modifiers(in: shortcut.modifiers).map(\.name) + [key(shortcut.key).name]).joined(separator: " ")
    }

    /// A tooltip with its shortcut appended: "Add a new patient (⌘N)".
    static func help(_ text: String, _ shortcut: KeyboardShortcut) -> String {
        "\(text) (\(symbols(for: shortcut)))"
    }

    private struct KeyLabel {
        let glyph: String
        let name: String
    }

    private static func modifiers(in set: EventModifiers) -> [KeyLabel] {
        var result: [KeyLabel] = []
        if set.contains(.control) { result.append(KeyLabel(glyph: "⌃", name: "Control")) }
        if set.contains(.option) { result.append(KeyLabel(glyph: "⌥", name: "Option")) }
        if set.contains(.shift) { result.append(KeyLabel(glyph: "⇧", name: "Shift")) }
        if set.contains(.command) { result.append(KeyLabel(glyph: "⌘", name: "Command")) }
        return result
    }

    private static func key(_ key: KeyEquivalent) -> KeyLabel {
        switch key {
        case .return: return KeyLabel(glyph: "↩", name: "Return")
        case .escape: return KeyLabel(glyph: "esc", name: "Escape")
        case .tab: return KeyLabel(glyph: "⇥", name: "Tab")
        case .space: return KeyLabel(glyph: "Space", name: "Space")
        case .delete: return KeyLabel(glyph: "⌫", name: "Delete")
        case .deleteForward: return KeyLabel(glyph: "⌦", name: "Forward Delete")
        case .upArrow: return KeyLabel(glyph: "↑", name: "Up Arrow")
        case .downArrow: return KeyLabel(glyph: "↓", name: "Down Arrow")
        case .leftArrow: return KeyLabel(glyph: "←", name: "Left Arrow")
        case .rightArrow: return KeyLabel(glyph: "→", name: "Right Arrow")
        case .home: return KeyLabel(glyph: "↖", name: "Home")
        case .end: return KeyLabel(glyph: "↘", name: "End")
        case .pageUp: return KeyLabel(glyph: "⇞", name: "Page Up")
        case .pageDown: return KeyLabel(glyph: "⇟", name: "Page Down")
        default:
            let text = String(key.character).uppercased()
            return KeyLabel(glyph: text, name: text)
        }
    }
}

/// The app's own shortcuts, defined once so the binding and every hint that
/// mentions it come from the same value. `.defaultAction` and `.cancelAction`
/// are SwiftUI's own and already carry their key.
enum AppShortcut {
    static let newPatient = KeyboardShortcut("n", modifiers: .command)
    static let saveComment = KeyboardShortcut(.return, modifiers: .command)
}

extension View {
    /// Binds `shortcut` and appends it to the tooltip, so the two can't disagree.
    func shortcut(_ shortcut: KeyboardShortcut, help: String) -> some View {
        keyboardShortcut(shortcut).help(ShortcutGlyphs.help(help, shortcut))
    }
}
