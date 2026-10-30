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
    /// How wide the divider line lights up while hovered or dragged.
    static let highlightWidth: CGFloat = 3
}

#if canImport(AppKit)
/// The grab area over a pane divider: shows the left-right resize cursor,
/// lights the divider line while the mouse is over it or dragging, and reports
/// how far the mouse has moved since it went down. Size it with
/// `PaneDivider.gripWidth` and place it `PaneDivider.gripLead` before the line.
struct PaneDividerGrip: View {
    var accessibilityID: String?
    var accessibilityLabel: String?
    let onDrag: (CGFloat) -> Void
    var onClick: () -> Void = {}
    var onEnd: () -> Void = {}
    @State private var lit = false

    var body: some View {
        PaneDividerGripArea(
            accessibilityID: accessibilityID, accessibilityLabel: accessibilityLabel,
            onDrag: onDrag, onClick: onClick, onEnd: onEnd,
            onActive: { active in withAnimation(.easeOut(duration: 0.12)) { lit = active } })
            // Behind the grab area, so the mouse always lands on the AppKit view.
            .background(alignment: .leading) {
                Rectangle()
                    .fill(Theme.accent.color)
                    .frame(width: PaneDivider.highlightWidth)
                    .offset(x: PaneDivider.gripLead + 0.5 - PaneDivider.highlightWidth / 2)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

/// The AppKit half of `PaneDividerGrip`. An AppKit view because the panes hold
/// AppKit scroll views, and a SwiftUI gesture laid over them never receives the mouse.
private struct PaneDividerGripArea: NSViewRepresentable {
    var accessibilityID: String?
    var accessibilityLabel: String?
    let onDrag: (CGFloat) -> Void
    let onClick: () -> Void
    let onEnd: () -> Void
    let onActive: (Bool) -> Void

    func makeNSView(context: Context) -> PaneDividerGripView { PaneDividerGripView() }
    func updateNSView(_ nsView: PaneDividerGripView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onClick = onClick
        nsView.onEnd = onEnd
        nsView.onActive = onActive
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
    /// Whether the divider should look live: hovered or being dragged.
    var onActive: (Bool) -> Void = { _ in }
    private var downX: CGFloat?
    private var moved = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // A tracking-area cursor update rather than a cursor rect: SwiftUI's hosting
    // views set the cursor through cursor updates too, and theirs won over a rect.
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Removed mid-drag (the pane collapsed): give the arrow back.
        if newWindow == nil, downX != nil { NSCursor.arrow.set() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        // Moved out from under a still mouse (a drag collapsed the pane): AppKit
        // sends no exit for that, so go dark here.
        if hovered, !mouseIsInside() {
            hovered = false
            if downX == nil { onActive(false) }
        }
    }

    private func mouseIsInside(_ windowPoint: NSPoint? = nil) -> Bool {
        guard let window else { return false }
        let point = windowPoint ?? window.mouseLocationOutsideOfEventStream
        return bounds.contains(convert(point, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onActive(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        if downX == nil { onActive(false) }
    }

    override func mouseDown(with event: NSEvent) {
        downX = event.locationInWindow.x
        moved = false
        NSCursor.resizeLeftRight.set()
        onActive(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downX else { return }
        // The mouse runs ahead of the edge; keep the resize cursor until it lets go.
        NSCursor.resizeLeftRight.set()
        if abs(event.locationInWindow.x - downX) > 3 { moved = true }
        onDrag(event.locationInWindow.x - downX)
    }

    override func mouseUp(with event: NSEvent) {
        guard downX != nil else { return }
        downX = nil
        let wasClick = !moved
        hovered = mouseIsInside(event.locationInWindow)
        if !hovered { onActive(false) }
        onEnd()
        if wasClick { onClick() }
    }
}
#endif
