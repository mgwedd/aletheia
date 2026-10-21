import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The transcript on the left and its comments on the right, per
/// `TranscriptSplit`: the comments appear only when there are some, a
/// draggable divider sets the split, and a side that gets too narrow folds into
/// an arrow strip that opens it again.
struct TranscriptSplitView<Transcript: View, Comments: View>: View {
    let hasComments: Bool
    let commentCount: Int
    /// The transcript's share of the pane, kept by the owner (and remembered).
    @Binding var ratio: Double
    @Binding var collapsed: TranscriptSplit.Side?
    /// Bumped when a comment is brought into focus; a collapsed comments pane
    /// opens for it when there is room.
    let revealToken: Int
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let comments: () -> Comments

    /// The transcript's width when the current drag began.
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let layout = TranscriptSplit.layout(
                total: total, ratio: ratio, hasComments: hasComments, collapsed: collapsed
            )
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if layout.strip == .transcript {
                        strip(.transcript, total: total).transition(.opacity)
                    } else {
                        transcript()
                            .frame(width: layout.transcript)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                    if layout.showsDivider {
                        Rectangle()
                            .fill(Theme.line.color)
                            .frame(width: TranscriptSplit.dividerWidth)
                    }
                    if layout.strip == .comments {
                        strip(.comments, total: total).transition(.opacity)
                    } else if layout.comments > 0 {
                        comments()
                            .frame(width: layout.comments)
                            .frame(maxHeight: .infinity)
                            .transition(.opacity)
                    }
                }
                if layout.showsDivider || (layout.strip != nil && TranscriptSplit.fitsBoth(total: total)) {
                    grip(layout: layout, total: total)
                }
            }
            .onChange(of: revealToken) { _, _ in
                let next = TranscriptSplit.revealingComments(collapsed: collapsed, total: total)
                if next != collapsed { withAnimation(Self.animation) { collapsed = next } }
            }
        }
    }

    /// How the split animates when a side collapses or opens.
    private static var animation: Animation { .easeInOut(duration: 0.22) }

    /// An invisible strip that takes the drag: over the divider (reaching into
    /// the comments side, so it never covers the transcript's scroll bar), or,
    /// when a side is collapsed, over the strip's inner edge, so the side can be
    /// dragged back open. It is an AppKit view: the transcript and the comments
    /// are AppKit scroll views, and a SwiftUI gesture laid over them never
    /// receives the mouse. A click on it (no drag) acts as the strip's arrow.
    private func grip(layout: TranscriptSplit.Layout, total: CGFloat) -> some View {
        let x: CGFloat
        switch layout.strip {
        case .transcript?: x = TranscriptSplit.stripWidth - Self.gripWidth
        case .comments?: x = layout.transcript
        case nil: x = layout.transcript - 1
        }
        return DividerGrip(
            onDrag: { translation in
                let start = dragStart ?? TranscriptSplit.dragOrigin(layout, total: total)
                dragStart = start
                apply(TranscriptSplit.resolveDrag(proposedTranscript: start + translation, total: total))
            },
            onClick: {
                if let side = layout.strip { open(side, total: total) }
            },
            onEnd: { dragStart = nil }
        )
        .frame(width: Self.gripWidth)
        .frame(maxHeight: .infinity)
        .offset(x: x)
        .accessibilityHidden(true)
    }

    private static var gripWidth: CGFloat { 8 }

    private func apply(_ result: TranscriptSplit.DragResult) {
        switch result {
        case .resize(let newRatio):
            // A drag out of a strip opens the side as it crosses its slack.
            if collapsed != nil { withAnimation(Self.animation) { collapsed = nil } }
            if newRatio != ratio { ratio = newRatio }
        case .collapse(let side):
            if collapsed != side { withAnimation(Self.animation) { collapsed = side } }
        }
    }

    private func open(_ side: TranscriptSplit.Side, total: CGFloat) {
        withAnimation(Self.animation) {
            ratio = TranscriptSplit.defaultRatio
            collapsed = TranscriptSplit.expanded(opening: side, total: total)
        }
    }

    /// What is left of a collapsed side: a thin column with an arrow pointing
    /// the way it will open.
    private func strip(_ side: TranscriptSplit.Side, total: CGFloat) -> some View {
        CollapsedStrip(
            opensComments: side == .comments, count: commentCount,
            action: { open(side, total: total) }
        )
    }
}

/// A collapsed side: a full-height column with a bold arrow pointing the way it
/// opens, which lights up under the pointer.
private struct CollapsedStrip: View {
    let opensComments: Bool
    let count: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: opensComments ? "chevron.left" : "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: TranscriptSplit.stripWidth, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.color)
            .help(opensComments ? "Show comments" : "Show transcript")
            .accessibilityLabel(opensComments ? "Show comments" : "Show transcript")
            if opensComments {
                Text("\(count)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.text.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: TranscriptSplit.stripWidth)
        .frame(maxHeight: .infinity)
        .background(hovering ? Theme.hover.color : Theme.panel.color)
        .overlay(alignment: opensComments ? .leading : .trailing) {
            Rectangle().fill(Theme.line.color).frame(width: TranscriptSplit.dividerWidth)
        }
        .onHover { hovering = $0 }
    }
}

#if canImport(AppKit)
/// The divider's drag handle: shows the left-right resize cursor and reports
/// how far the mouse has moved since it went down.
private struct DividerGrip: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onClick: () -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> TranscriptSplitGripView { TranscriptSplitGripView() }
    func updateNSView(_ nsView: TranscriptSplitGripView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onClick = onClick
        nsView.onEnd = onEnd
    }
}

final class TranscriptSplitGripView: NSView {
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
