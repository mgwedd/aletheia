import AppKit
@testable import Aletheia

/// The window tests host views in. While the test host runs in the background
/// it is transparent and click-through, so test runs don't draw over the
/// developer's screen. Tests use this, never `NSWindow(...)` directly.
final class TestWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        isReleasedWhenClosed = false
        MainActor.assumeIsolated { TestHost.conceal(self) }
    }
}
