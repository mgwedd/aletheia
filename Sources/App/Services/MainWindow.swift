import AppKit
import SwiftUI

/// Brings the main window to the front: from the menu bar, and after an unlock.
enum MainWindow {
    /// The main `WindowGroup`'s id, for reopening it with `openWindow`.
    static let id = "main"

    /// The real main window, captured by `MainWindowCapture` (weak: nil once closed and freed).
    @MainActor static weak var window: NSWindow?

    /// Whether the main window has to be opened: it is gone, or closed (neither
    /// visible nor minimised) while the app isn't merely hidden.
    static func needsOpen(exists: Bool, isVisible: Bool, isMiniaturized: Bool, appHidden: Bool) -> Bool {
        !exists || (!isVisible && !isMiniaturized && !appHidden)
    }

    /// The menu-bar panel, if it is the key window. Take it before any `await`, so a
    /// system or save panel that becomes key later is never ordered out instead.
    @MainActor static func menuBarPanel() -> NSWindow? {
        guard let key = NSApp.keyWindow, key is NSPanel,
              String(describing: type(of: key)).contains("MenuBarExtra") else { return nil }
        return key
    }

    /// Activate the app and raise the main window, reopening it if it was closed.
    @MainActor static func show(openWindow: OpenWindowAction) {
        show(openWindow: openWindow, panel: menuBarPanel())
    }

    @MainActor static func show(openWindow: OpenWindowAction, panel: NSWindow?) {
        panel?.orderOut(nil)
        let hidden = NSApp.isHidden
        if hidden { NSApp.unhide(nil) }
        NSApp.activate()
        if needsOpen(exists: window != nil, isVisible: window?.isVisible ?? false,
                     isMiniaturized: window?.isMiniaturized ?? false, appHidden: hidden) {
            openWindow(id: id)
        } else {
            makeKey(restoring: true)
        }
    }

    /// Make the main window key. A window the user minimised is only restored when asked to.
    /// If the main window is closed (e.g. only the patient chat window is open), falls back
    /// to the first visible non-panel window so unlocking still hands focus back.
    @MainActor static func makeKey(restoring: Bool = false) {
        if let window {
            if window.isMiniaturized {
                guard restoring else { return }
                window.deminiaturize(nil)
            }
            if window.isVisible {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        if NSApp.keyWindow == nil {
            NSApp.windows.first { $0.isVisible && !$0.isMiniaturized && !($0 is NSPanel) }?
                .makeKeyAndOrderFront(nil)
        }
    }
}

/// Put in the main window's content so `MainWindow` knows its real `NSWindow`.
struct MainWindowCapture: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { MainWindow.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { MainWindow.window = view.window }
    }
}
