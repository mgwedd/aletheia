import SwiftUI

/// The app's own shortcuts, defined once so a binding, its tooltip, its on-screen
/// hint and the Keyboard Shortcuts window all read the same value. (Not named
/// `AppShortcut`: that is AppIntents' type.) `.defaultAction` and `.cancelAction`
/// are SwiftUI's own and already carry their key.
enum AppHotkey {
    /// Focuses the search field at the top right (global search). While a
    /// transcript or note has the cursor it opens that text's own find bar instead.
    static let search = KeyboardShortcut("f", modifiers: .command)
    static let newPatient = KeyboardShortcut("n", modifiers: .command)
    static let closeWindow = KeyboardShortcut("w", modifiers: .command)
    static let showShortcuts = KeyboardShortcut("/", modifiers: .command)
    static let saveComment = KeyboardShortcut(.return, modifiers: .command)
    /// Bound in `SessionDetailView` and `PatientProfileEditor` through these
    /// values; `ShortcutCatalogTests` fails if a literal ⌘S/⌘G binding returns.
    static let saveEdits = KeyboardShortcut("s", modifiers: .command)
    static let generateNote = KeyboardShortcut("g", modifiers: .command)

    /// The note editor's own keys. They're handled by its text view
    /// (`RichNoteEditor.performKeyEquivalent`), not by SwiftUI, so the editor's
    /// tooltips and this window are the only things built from these.
    static let bold = KeyboardShortcut("b", modifiers: .command)
    static let italic = KeyboardShortcut("i", modifiers: .command)
    static let bulletedList = KeyboardShortcut("7", modifiers: [.command, .shift])
    static let numberedList = KeyboardShortcut("9", modifiers: [.command, .shift])
    static let bodyText = KeyboardShortcut("b", modifiers: [.command, .shift])
    static let heading = KeyboardShortcut("h", modifiers: [.command, .shift])
    static let subheading = KeyboardShortcut("j", modifiers: [.command, .shift])
}

/// One row of the Keyboard Shortcuts window.
struct ShortcutEntry: Identifiable {
    let title: String
    let shortcut: KeyboardShortcut

    var id: String { title }
}

struct ShortcutSection: Identifiable {
    let title: String
    let entries: [ShortcutEntry]

    var id: String { title }
}

/// What the Keyboard Shortcuts window lists, built from `AppHotkey`.
enum ShortcutCatalog {
    /// The standard Settings item's key; the system binds it, so it isn't in `AppHotkey`.
    static let settings = KeyboardShortcut(",", modifiers: .command)

    static let sections: [ShortcutSection] = [
        ShortcutSection(title: "Patients and sessions", entries: [
            ShortcutEntry(title: "Search everything", shortcut: AppHotkey.search),
            ShortcutEntry(title: "New patient", shortcut: AppHotkey.newPatient),
            ShortcutEntry(title: "Save your edits", shortcut: AppHotkey.saveEdits),
            ShortcutEntry(title: "Generate or regenerate the note", shortcut: AppHotkey.generateNote),
            ShortcutEntry(title: "Save a comment", shortcut: AppHotkey.saveComment),
            ShortcutEntry(title: "Close a sheet or search", shortcut: .cancelAction),
        ]),
        ShortcutSection(title: "Writing a note", entries: [
            ShortcutEntry(title: "Bold", shortcut: AppHotkey.bold),
            ShortcutEntry(title: "Italic", shortcut: AppHotkey.italic),
            ShortcutEntry(title: "Bulleted list", shortcut: AppHotkey.bulletedList),
            ShortcutEntry(title: "Numbered list", shortcut: AppHotkey.numberedList),
            ShortcutEntry(title: "Body text", shortcut: AppHotkey.bodyText),
            ShortcutEntry(title: "Heading", shortcut: AppHotkey.heading),
            ShortcutEntry(title: "Subheading", shortcut: AppHotkey.subheading),
        ]),
        ShortcutSection(title: "Windows", entries: [
            ShortcutEntry(title: "Settings", shortcut: settings),
            ShortcutEntry(title: "Close window", shortcut: AppHotkey.closeWindow),
            ShortcutEntry(title: "Keyboard shortcuts", shortcut: AppHotkey.showShortcuts),
        ]),
    ]
}

/// The Keyboard Shortcuts window (`AletheiaApp`), opened from the Help menu.
enum ShortcutsWindow {
    static let id = "shortcuts"
}
