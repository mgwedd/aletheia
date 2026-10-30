import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The one size for every draggable divider between two panes.
enum PaneDivider {
    /// How wide the grab area is.
    static let gripWidth: CGFloat = 12
    /// How far the grab area reaches back over the left pane; the rest lies over
    /// the right one, so it never covers the left pane's scroll bar.
    static let gripLead: CGFloat = 1
}

#if canImport(AppKit)
/// The invisible grab area over a pane divider: shows the left-right resize
/// cursor and reports how far the mouse has moved since it went down. It is an
/// AppKit view because the panes hold AppKit scroll views, and a SwiftUI gesture
/// laid over them never receives the mouse. Size it with `PaneDivider.gripWidth`.
struct PaneDividerGrip: NSViewRepresentable {
    var accessibilityID: String?
    var accessibilityLabel: String?
    let onDrag: (CGFloat) -> Void
    var onClick: () -> Void = {}
    var onEnd: () -> Void = {}

    func makeNSView(context: Context) -> PaneDividerGripView { PaneDividerGripView() }
    func updateNSView(_ nsView: PaneDividerGripView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onClick = onClick
        nsView.onEnd = onEnd
        nsView.setAccessibilityElement(accessibilityID != nil)
        nsView.setAccessibilityRole(.splitter)
        nsView.setAccessibilityIdentifier(accessibilityID)
        nsView.setAccessibilityLabel(accessibilityLabel)
    }
}

final class PaneDividerGripView: NSView {
    var onDrag: (CGFloat) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onEnd: () -> Void = {}
    private var downX: CGFloat?
    private var moved = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        downX = event.locationInWindow.x
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downX else { return }
        if abs(event.locationInWindow.x - downX) > 3 { moved = true }
        onDrag(event.locationInWindow.x - downX)
    }

    override func mouseUp(with event: NSEvent) {
        guard downX != nil else { return }
        downX = nil
        let wasClick = !moved
        onEnd()
        if wasClick { onClick() }
    }
}
#endif
