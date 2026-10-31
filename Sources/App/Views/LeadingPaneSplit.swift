import SwiftUI

/// How wide the patients sidebar may be dragged.
enum SidebarLayout {
    static let minWidth: CGFloat = 220
    static let idealWidth: CGFloat = 280
    static let maxWidth: CGFloat = 440
    /// What the page beside it keeps, however wide the sidebar is dragged.
    static let contentMinWidth: CGFloat = 460
    /// Dragged narrower than this, the sidebar collapses, as a system split view's does.
    static let collapseWidth: CGFloat = minWidth / 2

    static func width(proposed: CGFloat) -> CGFloat {
        min(max(proposed, minWidth), maxWidth)
    }

    /// The width for `proposed` in a window `total` wide: within the sidebar's
    /// limits, and narrowing first when the page beside it would drop under its own.
    static func width(proposed: CGFloat, total: CGFloat) -> CGFloat {
        let room = total - contentMinWidth
        return max(minWidth, min(width(proposed: proposed), room))
    }
}

/// A resizable pane at the leading edge beside the rest of the window, with a
/// visible line and the shared grab strip between them: every draggable split
/// with a leading pane uses it, so they look and drag alike. Dragged under its
/// narrowest, the pane follows the mouse with resistance, then springs back when
/// let go; one that collapses shows it is about to close, and past
/// `collapseWidth` it slides shut while the mouse is still down, keeping the
/// width it had before the drag. Dragged back out from the window's leading
/// edge, it slides open.
///
/// Its own row rather than a system split view: the system sidebar restored
/// its layout at launch and sometimes came up blank. This one is laid out from
/// `width` every time, clamps to the window on every layout (so a narrow
/// window never pushes the page off screen), and clips each pane to its
/// bounds, while overlays, popovers and sheets still draw outside them.
struct LeadingPaneSplit<Pane: View, Content: View>: View {
    /// Where the edge was last dragged; clamped by `limit` when laid out.
    @Binding var width: Double
    @Binding var isShown: Bool
    /// The width for a proposed width in a window this wide.
    let limit: (_ proposed: CGFloat, _ total: CGFloat) -> CGFloat
    /// Dragged narrower than this, the pane collapses; nil for one that never does.
    let collapseWidth: CGFloat?
    let dividerID: String
    let dividerLabel: String
    /// The strip at the window's edge while the pane is hidden.
    let revealID: String
    let revealLabel: String
    /// Whether anything sits beside the pane. Without it the pane takes the
    /// whole width, with no line or grip; it comes back sliding in from the
    /// trailing edge.
    var showsContent: Bool = true
    @ViewBuilder let pane: () -> Pane
    @ViewBuilder let content: () -> Content
    /// Where the edge was when the drag began: 0 while the pane is hidden.
    @State private var dragStart: CGFloat?
    /// Restored when a drag collapses the pane.
    @State private var widthBeforeDrag: Double?
    /// The pane's width while a drag holds it under its narrowest.
    @State private var stretchedWidth: CGFloat?

    private static var slide: Animation { .easeInOut(duration: 0.2) }

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let shown = stretchedWidth ?? limit(CGFloat(width), total)
            HStack(spacing: 0) {
                if isShown {
                    // One fixed width with or without content beside it:
                    // switching between a fixed and a flexible frame left the
                    // pane at its full width when the content came back.
                    pane()
                        .frame(width: showsContent ? shown : total)
                        .frame(maxHeight: .infinity)
                        .clipped()
                        .transition(.move(edge: .leading))
                }
                if showsContent {
                    HStack(spacing: 0) {
                        if isShown {
                            Rectangle()
                                .fill(Theme.line.color)
                                .frame(width: 1)
                                .frame(maxHeight: .infinity)
                        }
                        content()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                    }
                    .transition(.move(edge: .trailing))
                }
            }
            // One grip, shown or hidden, so a drag that collapses or reveals the
            // pane keeps going with the same mouse press.
            .overlay(alignment: .topLeading) {
                if showsContent {
                PaneDividerGrip(
                    accessibilityID: isShown ? dividerID : revealID,
                    accessibilityLabel: isShown ? dividerLabel : revealLabel,
                    onDrag: { translation in
                        let start = dragStart ?? (isShown ? shown : 0)
                        if dragStart == nil { dragStart = start; widthBeforeDrag = width }
                        let proposed = start + translation
                        if let collapseWidth, proposed < collapseWidth {
                            guard isShown else { return }
                            width = widthBeforeDrag ?? width
                            withAnimation(Self.slide) { stretchedWidth = nil; isShown = false }
                            return
                        }
                        let fitted = limit(proposed, total)
                        if Double(fitted) != width { width = Double(fitted) }
                        // Under the narrowest, give way half as fast as the mouse.
                        let stretched = proposed < fitted ? fitted - (fitted - proposed) / 2 : nil
                        if isShown {
                            stretchedWidth = stretched
                        } else {
                            withAnimation(Self.slide) { stretchedWidth = stretched; isShown = true }
                        }
                    },
                    onEnd: {
                        dragStart = nil
                        widthBeforeDrag = nil
                        if stretchedWidth != nil {
                            withAnimation(.easeOut(duration: 0.25)) { stretchedWidth = nil }
                        }
                    }
                )
                // Hidden, a narrower strip at the window's edge, to drag the pane back out.
                .frame(width: isShown ? PaneDivider.gripWidth : PaneDivider.gripWidth / 2)
                .frame(maxHeight: .infinity)
                .offset(x: isShown ? shown - PaneDivider.gripLead : 0)
                .transition(.opacity)
                }
            }
        }
    }
}

extension LeadingPaneSplit {
    /// A pane that never collapses: dragged under its narrowest it still gives
    /// way, then springs back when let go.
    init(
        width: Binding<Double>,
        limit: @escaping (_ proposed: CGFloat, _ total: CGFloat) -> CGFloat,
        dividerID: String, dividerLabel: String,
        showsContent: Bool = true,
        @ViewBuilder pane: @escaping () -> Pane,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            width: width, isShown: .constant(true), limit: limit, collapseWidth: nil,
            dividerID: dividerID, dividerLabel: dividerLabel, revealID: "", revealLabel: "",
            showsContent: showsContent, pane: pane, content: content)
    }
}
