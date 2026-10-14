import AppKit
import SwiftUI

/// Brings the main window to the front: from the menu bar, and after an unlock.
enum MainWindow {
    /// The main `WindowGroup`'s id; SwiftUI prefixes its NSWindow identifier with it.
    static let id = "main"

    /// Index of the main window among these identifiers (the Doctor and chat
    /// windows have their own ids), or nil when it isn't open.
    static func index(ofIdentifiers identifiers: [String?]) -> Int? {
        identifiers.firstIndex { $0 == id || $0?.hasPrefix(id + "-") == true }
    }

    private static var window: NSWindow? {
        let windows = NSApp.windows
        return index(ofIdentifiers: windows.map { $0.identifier?.rawValue }).map { windows[$0] }
    }

    /// Activate the app and raise the main window, reopening it if it was closed.
    @MainActor static func show(openWindow: OpenWindowAction) {
        // The menu-bar panel is a key panel; close it so focus can move on.
        (NSApp.keyWindow as? NSPanel)?.orderOut(nil)
        NSApp.activate()
        if window != nil { makeKey() } else { openWindow(id: id) }
    }

    @MainActor static func makeKey() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}
