import AppKit

/// Makes Return (and keypad Enter) press the keyboard-focused button.
///
/// With Full Keyboard Access, Tab moves focus onto SwiftUI buttons but macOS
/// only presses a focused button with Space. SwiftUI keeps that focus in an
/// internal key-view proxy (not an `NSButton`), so there is nothing to
/// `performClick` on; instead a Return aimed at the proxy is rewritten into a
/// Space, which SwiftUI already treats as "press". Text fields and editors
/// have their own field editor as first responder, so they never match and
/// keep inserting newlines / submitting.
enum ReturnKeyActivation {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let spaceKeyCode: UInt16 = 49
    private static var monitor: Any?

    /// Whether a Return aimed at `responder` should become a button press.
    /// `responder` is the window's first responder.
    static func shouldActivate(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool, responder: NSResponder?
    ) -> Bool {
        guard keyCode == returnKeyCode || keyCode == keypadEnterKeyCode, !isRepeat else { return false }
        guard modifiers.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad).isEmpty else { return false }
        guard let responder, !(responder is NSTextView), !(responder is NSTextField) else { return false }
        return String(describing: type(of: responder)).contains("KeyViewProxy")
    }

    /// The Space key-down that stands in for `event`, or `event` unchanged.
    static func translated(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown,
              shouldActivate(
                keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat,
                responder: event.window?.firstResponder),
              let space = NSEvent.keyEvent(
                with: .keyDown, location: event.locationInWindow, modifierFlags: [],
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: spaceKeyCode)
        else { return event }
        return space
    }

    /// Idempotent; call once at launch.
    @MainActor static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { translated($0) }
    }
}
