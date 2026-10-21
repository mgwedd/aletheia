import CoreGraphics
import Foundation

/// How the session pane divides its width between the transcript and its
/// comments. Pure, so every width and every drag is decided (and tested) here
/// rather than inside a view.
///
/// - With no comments the transcript takes the whole pane.
/// - With comments the two sit side by side at `ratio` (the transcript's share),
///   each held to a readable minimum.
/// - A side that is dragged, or squeezed by a narrow window, below its minimum
///   collapses to an edge strip with an arrow that brings it back.
enum TranscriptSplit {
    enum Side: Equatable { case transcript, comments }

    static let minTranscript: CGFloat = 360
    static let minComments: CGFloat = 220
    static let dividerWidth: CGFloat = 1
    /// The width of the strip a collapsed side leaves behind (it carries the arrow).
    static let stripWidth: CGFloat = 24
    /// How far past a minimum a drag may go before the side collapses, so a
    /// drag stops at the minimum first rather than snapping shut on contact.
    static let collapseSlack: CGFloat = 48
    static let defaultRatio: Double = 2.0 / 3.0
    static let ratioRange: ClosedRange<Double> = 0.1...0.9

    struct Layout: Equatable {
        var transcript: CGFloat
        var comments: CGFloat
        /// The collapsed side, which shows an arrow strip.
        var strip: Side?
        var showsDivider: Bool
    }

    static func sanitized(ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultRatio }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// Whether the pane is wide enough for both sides at their minimums.
    static func fitsBoth(total: CGFloat) -> Bool {
        total - dividerWidth >= minTranscript + minComments
    }

    /// The side that is collapsed: the one the reader chose, or, when nothing
    /// was chosen and both can't fit, the comments (the transcript is the content).
    static func effectiveCollapse(collapsed: Side?, total: CGFloat) -> Side? {
        collapsed ?? (fitsBoth(total: total) ? nil : .comments)
    }

    static func layout(total: CGFloat, ratio: Double, hasComments: Bool, collapsed: Side?) -> Layout {
        guard hasComments else {
            return Layout(transcript: total, comments: 0, strip: nil, showsDivider: false)
        }
        switch effectiveCollapse(collapsed: collapsed, total: total) {
        case .comments?:
            return Layout(transcript: max(0, total - stripWidth), comments: 0, strip: .comments, showsDivider: false)
        case .transcript?:
            return Layout(transcript: 0, comments: max(0, total - stripWidth), strip: .transcript, showsDivider: false)
        case nil:
            let usable = total - dividerWidth
            let wanted = (usable * CGFloat(sanitized(ratio: ratio))).rounded()
            let transcript = min(max(wanted, minTranscript), usable - minComments)
            return Layout(transcript: transcript, comments: usable - transcript, strip: nil, showsDivider: true)
        }
    }

    enum DragResult: Equatable {
        case resize(ratio: Double)
        case collapse(Side)
    }

    /// What dragging the divider so the transcript is `proposedTranscript` wide
    /// does. Only meaningful while both sides fit (the divider isn't shown otherwise).
    static func resolveDrag(proposedTranscript: CGFloat, total: CGFloat) -> DragResult {
        let usable = total - dividerWidth
        if proposedTranscript < minTranscript - collapseSlack { return .collapse(.transcript) }
        if usable - proposedTranscript < minComments - collapseSlack { return .collapse(.comments) }
        let clamped = min(max(proposedTranscript, minTranscript), usable - minComments)
        return .resize(ratio: sanitized(ratio: Double(clamped / usable)))
    }

    /// The collapse state after the arrow on the `side` strip is pressed. With
    /// room for both, everything opens (nil). Without, the two swap: opening the
    /// comments collapses the transcript and the reverse.
    static func expanded(opening side: Side, total: CGFloat) -> Side? {
        if fitsBoth(total: total) { return nil }
        return side == .comments ? .transcript : .comments
    }

    /// The collapse state once a comment is brought into focus (a click on its
    /// highlight): a collapsed comments pane opens if there is room for it
    /// beside the transcript, and is otherwise left alone.
    static func revealingComments(collapsed: Side?, total: CGFloat) -> Side? {
        collapsed == .comments && fitsBoth(total: total) ? nil : collapsed
    }
}

/// Where the floating Comment button sits relative to the selection.
enum CommentButtonPlacement {
    static let size = CGSize(width: 108, height: 30)
    static let gap: CGFloat = 6
    static let margin: CGFloat = 8

    /// The button's top-left corner for a selection whose first line is `anchor`
    /// (in the pane's coordinates): above that line when there is room, else
    /// below it, kept inside the pane. Nil when the line has scrolled out of
    /// view or the pane is too narrow to hold the button.
    static func origin(anchor: CGRect, in pane: CGSize) -> CGPoint? {
        guard anchor.maxY > 0, anchor.minY < pane.height,
              pane.width >= size.width + 2 * margin else { return nil }
        let above = anchor.minY - gap - size.height
        let preferred = above >= margin ? above : anchor.maxY + gap
        let y = min(max(preferred, margin), pane.height - size.height - margin)
        let x = min(max(anchor.minX, margin), pane.width - size.width - margin)
        return CGPoint(x: x, y: y)
    }

    /// Whether the button shows: a passage is selected, there are no unsaved
    /// edits (a comment is pinned to the saved text), nothing is being
    /// composed, and the transcript can be read.
    static func isVisible(
        hasSelection: Bool, isDirty: Bool, isComposing: Bool, isReadable: Bool
    ) -> Bool {
        hasSelection && !isDirty && !isComposing && isReadable
    }
}
