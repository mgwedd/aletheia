import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// A read-only transcript view that supports the Google-Docs-style interaction
/// the therapist wants: drag to select any passage with the mouse or keyboard,
/// and see the passages that already carry a comment highlighted in place and
/// clickable. SwiftUI's `Text` can't expose a live selection or hit-test custom
/// ranges, so this wraps an `NSTextView` — kept deliberately thin, with the
/// which-range-is-which logic living in the pure `TranscriptHighlighter`.
///
///  - `selection` reports the currently selected substring (empty when the
///    selection is just a caret), so a "Comment on selection" button can enable
///    and prefill itself. `selectionRange` reports where it sits (UTF-16, nil
///    for a caret) so a comment can be pinned to *that* occurrence rather than
///    the first place the same words appear.
///  - `onOpenComment` fires when the reader clicks a highlighted passage,
///    carrying the id of the comment anchored there. The comment is found from
///    the clicked character's position within the resolved highlight ranges,
///    not by re-searching the quote.
#if canImport(AppKit)
struct TranscriptTextView: NSViewRepresentable {
    let transcript: String
    /// (comment id, quoted passage, quote start) triples — the same `quotedText`
    /// and `quoteStart` comments store. Only the passages you want highlighted
    /// (e.g. unresolved comments).
    let comments: [TranscriptHighlighter.Anchor]
    @Binding var selection: String
    @Binding var selectionRange: NSRange?
    var onOpenComment: (String) -> Void = { _ in }
    /// When set, the passage this comment anchors to is scrolled into view and
    /// briefly flashed — the "click a card in the rail → jump to the text"
    /// direction of the Google-Docs two-way focus. Cleared by the owner.
    var focusedCommentID: String? = nil
    /// Bumped by the owner on every focus request (a card or highlight click).
    /// The scroll-and-flash fires whenever this changes, even if
    /// `focusedCommentID` is the same one as last time, so clicking the same
    /// card again after scrolling away jumps back to its passage.
    var focusToken: Int = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = context.coordinator
        textView.isAutomaticLinkDetectionEnabled = false
        // A commented passage is a link under the hood (so clicks hit-test for
        // free) but must not look like a blue web link — keep body colour, no
        // underline, just a pointing-hand cursor.
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .cursor: NSCursor.pointingHand,
        ]
        context.coordinator.render(into: textView, transcript: transcript, comments: comments)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        // Only rebuild when the text or the set of comment anchors actually
        // changed; rebuilding on every SwiftUI pass would clobber the user's
        // in-progress selection.
        context.coordinator.render(into: textView, transcript: transcript, comments: comments)
        context.coordinator.flashIfNeeded(in: textView, focusedCommentID: focusedCommentID, focusToken: focusToken)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptTextView
        private var renderedSignature: Int?
        /// The focus token we last scrolled-and-flashed for, so re-flowing the
        /// view on unrelated SwiftUI passes doesn't re-trigger the flash.
        private var lastFlashedToken: Int?
        /// Where each highlighted comment currently sits, as of the last render.
        /// Both directions of navigation (flash a card's passage, map a click
        /// back to a card) read this rather than re-searching quote text.
        private var spans: [TranscriptHighlighter.Span] = []

        init(_ parent: TranscriptTextView) { self.parent = parent }

        /// Scrolls the passage anchored by `focusedCommentID` into view and
        /// flashes it, once per focus request (token change). Uses the layout
        /// manager's temporary attributes so the text storage (and thus the
        /// persisted highlight attributes) is never mutated. A comment whose passage couldn't be
        /// placed has no span, so focusing it leaves the scroll position alone.
        func flashIfNeeded(in textView: NSTextView, focusedCommentID: String?, focusToken: Int) {
            guard TranscriptHighlighter.isNewFocusRequest(
                commentID: focusedCommentID, token: focusToken, lastHandledToken: lastFlashedToken
            ), let id = focusedCommentID else {
                if focusedCommentID == nil { lastFlashedToken = nil }
                return
            }
            lastFlashedToken = focusToken
            guard
                let span = spans.first(where: { $0.commentID == id }),
                NSMaxRange(span.range) <= (textView.string as NSString).length,
                let layoutManager = textView.layoutManager
            else { return }

            textView.scrollRangeToVisible(span.range)
            let flash = NSColor.systemYellow.withAlphaComponent(0.55)
            layoutManager.addTemporaryAttributes([.backgroundColor: flash], forCharacterRange: span.range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
                layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: span.range)
            }
        }

        func render(into textView: NSTextView, transcript: String, comments: [TranscriptHighlighter.Anchor]) {
            let signature = Self.signature(transcript: transcript, comments: comments)
            guard signature != renderedSignature else { return }
            renderedSignature = signature

            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let attributed = NSMutableAttributedString(
                string: transcript,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            )
            let highlight = NSColor.systemYellow.withAlphaComponent(0.28)
            spans = TranscriptHighlighter.spans(in: transcript, comments: comments)
            // Overlapping highlights are fine (a later attribute simply replaces
            // an earlier one), but apply longest first so the most specific
            // passage owns the overlap — matching how clicks are resolved.
            let layers = spans.enumerated().sorted { a, b in
                a.element.range.length != b.element.range.length
                    ? a.element.range.length > b.element.range.length
                    : a.offset < b.offset
            }.map { $0.element }
            for span in layers {
                attributed.addAttribute(.backgroundColor, value: highlight, range: span.range)
                // The comment id is stored directly as the link value (NSTextView
                // accepts a String link) so it round-trips exactly, with no URL
                // host/case normalisation to undo.
                attributed.addAttribute(.link, value: span.commentID, range: span.range)
            }
            textView.textStorage?.setAttributedString(attributed)
        }

        private static func signature(transcript: String, comments: [TranscriptHighlighter.Anchor]) -> Int {
            var hasher = Hasher()
            hasher.combine(transcript)
            for comment in comments {
                hasher.combine(comment.id)
                hasher.combine(comment.quote)
                hasher.combine(comment.start)
            }
            return hasher.finalize()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let selected = range.length > 0
                ? (textView.string as NSString).substring(with: range)
                : ""
            if selected != parent.selection {
                parent.selection = selected
            }
            let selectedRange: NSRange? = range.length > 0 ? range : nil
            if selectedRange != parent.selectionRange {
                parent.selectionRange = selectedRange
            }
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            // Resolve by where the click landed within the placed highlights, so
            // two comments on the same repeated word stay distinct. The link
            // value (the comment id String we stored; NSTextView may hand it
            // back as a String or wrap it in a URL) is only a fallback.
            let id = TranscriptHighlighter.commentID(at: charIndex, in: spans)
                ?? (link as? String) ?? (link as? URL)?.absoluteString
            guard let id, !id.isEmpty else { return false }
            parent.onOpenComment(id)
            return true
        }
    }
}
#endif
