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
                        strip(.transcript, total: total)
                    } else {
                        transcript()
                            .frame(width: layout.transcript)
                            .frame(maxHeight: .infinity)
                    }
                    if layout.showsDivider {
                        Rectangle()
                            .fill(Theme.line.color)
                            .frame(width: TranscriptSplit.dividerWidth)
                    }
                    if layout.strip == .comments {
                        strip(.comments, total: total)
                    } else if layout.comments > 0 {
                        comments()
                            .frame(width: layout.comments)
                            .frame(maxHeight: .infinity)
                    }
                }
                if layout.showsDivider {
                    grip(layout: layout, total: total)
                }
            }
            .onChange(of: revealToken) { _, _ in
                collapsed = TranscriptSplit.revealingComments(collapsed: collapsed, total: total)
            }
        }
    }

    /// An invisible strip over the divider that takes the drag. It starts at the
    /// divider and reaches into the comments side, so it never covers the
    /// transcript's scroll bar.
    private func grip(layout: TranscriptSplit.Layout, total: CGFloat) -> some View {
        Color.clear
            .frame(width: Self.gripWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(ResizeCursorArea())
            .offset(x: layout.transcript - 1)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? layout.transcript
                        dragStart = start
                        apply(TranscriptSplit.resolveDrag(
                            proposedTranscript: start + value.translation.width, total: total
                        ))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityHidden(true)
    }

    private static var gripWidth: CGFloat { 8 }

    private func apply(_ result: TranscriptSplit.DragResult) {
        switch result {
        case .resize(let newRatio):
            if newRatio != ratio { ratio = newRatio }
        case .collapse(let side):
            collapsed = side
            dragStart = nil
        }
    }

    /// What is left of a collapsed side: a thin column with an arrow pointing
    /// the way it will open.
    private func strip(_ side: TranscriptSplit.Side, total: CGFloat) -> some View {
        let opensComments = side == .comments
        return VStack(spacing: 6) {
            Button {
                ratio = TranscriptSplit.defaultRatio
                collapsed = TranscriptSplit.expanded(opening: side, total: total)
            } label: {
                Image(systemName: opensComments ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: TranscriptSplit.stripWidth, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.muted.color)
            .help(opensComments ? "Show comments" : "Show transcript")
            .accessibilityLabel(opensComments ? "Show comments" : "Show transcript")
            if opensComments {
                Text("\(commentCount)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.muted.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .frame(width: TranscriptSplit.stripWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.window.color)
        .overlay(alignment: opensComments ? .leading : .trailing) {
            Rectangle().fill(Theme.line.color).frame(width: TranscriptSplit.dividerWidth)
        }
    }
}

#if canImport(AppKit)
/// A transparent overlay that shows the left-right resize cursor over its
/// bounds. Mouse events pass through it to the view below.
private struct ResizeCursorArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { CursorView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class CursorView: NSView {
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
