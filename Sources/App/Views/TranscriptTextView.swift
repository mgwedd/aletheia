import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The transcript text view: a plain-text `NSTextView` that is always editable
/// (click in, type, delete, cut/paste, undo/redo, select-all), with the passages
/// that carry a comment highlighted in place and clickable. SwiftUI's `Text` /
/// `TextEditor` can't expose a live selection or hit-test custom ranges, so this
/// wraps an `NSTextView` — kept deliberately thin, with the which-range-is-which
/// logic living in the pure `TranscriptHighlighter`.
///
///  - `text` is the text being edited. Typing writes through to it; an outside
///    change to it (Discard, a new transcription) replaces the view's content.
///    Nothing here saves anything: the owner decides when a draft is committed.
///  - `selection` reports the currently selected substring (empty when the
///    selection is just a caret), so a "Comment on selection" button can enable
///    and prefill itself. `selectionRange` reports where it sits (UTF-16, nil
///    for a caret) so a comment can be pinned to *that* occurrence rather than
///    the first place the same words appear.
///  - `onOpenComment` fires when the reader clicks (without dragging) inside a
///    highlighted passage, carrying the id of the comment anchored there. The
///    comment is found from the caret's position within the resolved highlight
///    ranges, not by re-searching the quote.
///
/// Highlights are re-resolved shortly after the text stops changing, and applied
/// by changing attributes in place, so the caret, the selection and the undo
/// history survive. A comment whose passage no longer resolves simply has no
/// highlight (the rail lists it as unplaced).
#if canImport(AppKit)
struct TranscriptTextView: NSViewRepresentable {
    @Binding var text: String
    /// False while the text must not be changed (e.g. the transcript could not
    /// be read, so saving would overwrite it).
    var isEditable: Bool = true
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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.panel.nsColor

        let contentSize = scroll.contentSize
        let textView = ClickReportingTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        // Plain text only: pasted styling is dropped, and nothing rewrites what
        // the therapist types (smart quotes, dashes, auto-correct) — the
        // transcript is a record, so what is typed is what is stored.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.panel.nsColor
        textView.font = Coordinator.font
        textView.textColor = Theme.text.nsColor
        textView.insertionPointColor = Theme.accent.nsColor
        textView.selectedTextAttributes = [.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor]
        // 24pt from the pane's edge, less the text container's own 5pt padding.
        textView.textContainerInset = NSSize(width: 19, height: 14)
        textView.delegate = context.coordinator
        textView.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleClick(at: index)
        }

        context.coordinator.sync(into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        textView.isEditable = isEditable
        // Only touch the view when the text or the set of comment anchors
        // actually changed; rebuilding on every SwiftUI pass would clobber the
        // user's caret and selection.
        context.coordinator.sync(into: textView)
        context.coordinator.flashIfNeeded(in: textView, focusedCommentID: focusedCommentID, focusToken: focusToken)
    }

    /// An `NSTextView` that reports a plain click (single click, no drag, so an
    /// empty selection) with the caret position it landed on. Used instead of the
    /// `.link` attribute, which in an editable text view doesn't reliably fire on
    /// a simple click.
    final class ClickReportingTextView: NSTextView {
        var onPlainClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event) // runs the whole press-drag-release
            guard event.clickCount == 1, selectedRange().length == 0 else { return }
            onPlainClick?(selectedRange().location)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.systemFont(ofSize: 15)
        static let timestampFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        /// Where the words start: time stamps sit in a column to the left, and a
        /// line that wraps continues at this indent, so each turn reads as a block.
        static let textColumn: CGFloat = 64
        static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            style.paragraphSpacing = 14
            style.headIndent = textColumn
            return style
        }()
        static var baseAttributes: [NSAttributedString.Key: Any] {
            [
                .font: font,
                .foregroundColor: Theme.text.nsColor,
                .paragraphStyle: paragraphStyle,
            ]
        }

        /// Time stamps recede; speaker labels carry the track's colour (the
        /// microphone green, the call amber). Attributes only: the characters
        /// are the stored transcript and are never rewritten.
        static func attributes(for role: TranscriptStyler.Role) -> [NSAttributedString.Key: Any] {
            switch role {
            case .timestamp:
                return [
                    .font: timestampFont,
                    .foregroundColor: Theme.muted.nsColor,
                ]
            case .speaker(let label):
                let color: NSColor
                switch TranscriptStyler.tone(for: label) {
                case .therapist: color = Theme.accent.nsColor
                case .callAudio: color = Theme.callAudio.nsColor
                case .other: color = Theme.muted.nsColor
                }
                return [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: color,
                ]
            }
        }

        /// Extra space after a time stamp so the speaker starts at `textColumn`.
        /// Set as kerning on the stamp's last character: the gap is drawn, but
        /// no character is added to the transcript.
        static func columnKern(forTimestamp stamp: String, trailingSpaces: String) -> CGFloat {
            let stampWidth = (stamp as NSString).size(withAttributes: [.font: timestampFont]).width
            let spaceWidth = (trailingSpaces as NSString).size(withAttributes: [.font: font]).width
            return max(0, textColumn - stampWidth - spaceWidth)
        }
        /// How long the text must sit still before highlights are re-resolved.
        private static let rehighlightDelay: TimeInterval = 0.2

        var parent: TranscriptTextView
        /// Signature of the comment anchors the highlights were last built for.
        private var appliedAnchorsSignature: Int?
        /// The focus token we last scrolled-and-flashed for, so re-flowing the
        /// view on unrelated SwiftUI passes doesn't re-trigger the flash.
        private var lastFlashedToken: Int?
        /// Where each highlighted comment currently sits, as of the last
        /// highlight pass. Both directions of navigation (flash a card's
        /// passage, map a click back to a card) read this rather than
        /// re-searching quote text.
        private var spans: [TranscriptHighlighter.Span] = []
        private var pendingRehighlight: DispatchWorkItem?
        /// True while this class is the one changing the view's content, so the
        /// resulting selection callbacks aren't mistaken for user input.
        private var isApplyingProgrammaticChange = false

        init(_ parent: TranscriptTextView) { self.parent = parent }

        // MARK: Syncing with SwiftUI

        /// Brings the view in line with the owner's `text` and `comments`.
        func sync(into textView: NSTextView) {
            if !Self.identical(textView.string, parent.text) {
                replaceContent(of: textView, with: parent.text)
                applyHighlights(to: textView)
            } else if Self.signature(of: parent.comments) != appliedAnchorsSignature {
                applyHighlights(to: textView)
            }
        }

        /// An outside change to the text (the draft was discarded, a new
        /// transcript arrived): replace the content, keep the caret as near as
        /// it was, and start a fresh undo history — old undo steps refer to
        /// ranges of text that no longer exists.
        private func replaceContent(of textView: NSTextView, with text: String) {
            pendingRehighlight?.cancel()
            let previous = textView.selectedRange()
            isApplyingProgrammaticChange = true
            defer { isApplyingProgrammaticChange = false }
            textView.textStorage?.setAttributedString(
                NSAttributedString(string: text, attributes: Self.baseAttributes)
            )
            let length = (text as NSString).length
            let location = min(previous.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(previous.length, length - location)))
            textView.typingAttributes = Self.baseAttributes
            textView.undoManager?.removeAllActions()
        }

        /// Re-resolves every comment against the current text and repaints the
        /// styling and highlight attributes in place. Only attributes change —
        /// never the characters — so the caret, selection and undo history are
        /// untouched.
        private func applyHighlights(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let anchors = parent.comments
            appliedAnchorsSignature = Self.signature(of: anchors)
            spans = TranscriptHighlighter.spans(in: storage.string, comments: anchors)

            let highlight = Theme.highlight.nsColor
            let highlightInk = Theme.highlightInk.nsColor
            // Overlapping highlights are fine (a later attribute simply replaces
            // an earlier one), but apply longest first so the most specific
            // passage owns the overlap — matching how clicks are resolved.
            let layers = spans.enumerated().sorted { a, b in
                a.element.range.length != b.element.range.length
                    ? a.element.range.length > b.element.range.length
                    : a.offset < b.offset
            }.map { $0.element }

            isApplyingProgrammaticChange = true
            defer { isApplyingProgrammaticChange = false }
            storage.beginEditing()
            // Reset to the base look (this also clears old highlights), then lay
            // the time stamp / speaker styling and the comment highlights on top.
            storage.setAttributes(Self.baseAttributes, range: NSRange(location: 0, length: storage.length))
            let string = storage.string as NSString
            for styled in TranscriptStyler.spans(in: storage.string) where NSMaxRange(styled.range) <= storage.length {
                storage.addAttributes(Self.attributes(for: styled.role), range: styled.range)
                if styled.role == .timestamp, styled.range.length > 0 {
                    let spaces = Self.whitespace(after: styled.range, in: string)
                    let kern = Self.columnKern(forTimestamp: string.substring(with: styled.range), trailingSpaces: spaces)
                    storage.addAttribute(.kern, value: kern, range: NSRange(location: NSMaxRange(styled.range) - 1, length: 1))
                }
            }
            for span in layers where NSMaxRange(span.range) <= storage.length {
                storage.addAttributes([.backgroundColor: highlight, .foregroundColor: highlightInk], range: span.range)
            }
            storage.endEditing()
        }

        /// The spaces and tabs directly after `range`.
        private static func whitespace(after range: NSRange, in string: NSString) -> String {
            var end = NSMaxRange(range)
            while end < string.length, let scalar = UnicodeScalar(string.character(at: end)), scalar == " " || scalar == "\t" {
                end += 1
            }
            return string.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
        }

        private func scheduleRehighlight(for textView: NSTextView) {
            pendingRehighlight?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.applyHighlights(to: textView)
            }
            pendingRehighlight = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.rehighlightDelay, execute: work)
        }

        /// Code-unit equality. Swift's `==` treats canonically-equivalent strings
        /// (precomposed vs. decomposed accents) as equal, which would let a change
        /// the text view made go unreported.
        private static func identical(_ a: String, _ b: String) -> Bool {
            a.utf16.elementsEqual(b.utf16)
        }

        private static func signature(of comments: [TranscriptHighlighter.Anchor]) -> Int {
            var hasher = Hasher()
            for comment in comments {
                hasher.combine(comment.id)
                hasher.combine(comment.quote)
                hasher.combine(comment.start)
            }
            return hasher.finalize()
        }

        // MARK: Focus (scroll and flash)

        /// Scrolls the passage anchored by `focusedCommentID` into view and
        /// flashes it, once per focus request (token change). Uses the layout
        /// manager's temporary attributes so the text storage is never mutated.
        /// A comment whose passage couldn't be placed has no span, so focusing
        /// it leaves the scroll position alone.
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
            let flash = Theme.accentTint.nsColor
            layoutManager.addTemporaryAttributes([.backgroundColor: flash], forCharacterRange: span.range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
                layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: span.range)
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticChange, let textView = notification.object as? NSTextView else { return }
            // Text typed at the edge of a highlight inherits its background;
            // new text starts plain and the next pass decides what is highlighted.
            textView.typingAttributes = Self.baseAttributes
            if !Self.identical(parent.text, textView.string) {
                parent.text = textView.string
            }
            scheduleRehighlight(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let selected = range.length > 0
                ? (textView.string as NSString).substring(with: range)
                : ""
            let selectedRange: NSRange? = range.length > 0 ? range : nil
            let publish = { [weak self] in
                guard let self else { return }
                if selected != self.parent.selection { self.parent.selection = selected }
                if selectedRange != self.parent.selectionRange { self.parent.selectionRange = selectedRange }
            }
            if isApplyingProgrammaticChange {
                // Raised from inside a SwiftUI update pass: don't write state now.
                DispatchQueue.main.async(execute: publish)
            } else {
                publish()
            }
        }

        /// A plain click at `index`: if it landed inside a highlighted passage,
        /// resolve by where it landed within the placed highlights, so two
        /// comments on the same repeated word stay distinct.
        func handleClick(at index: Int) {
            guard let id = TranscriptHighlighter.commentID(at: index, in: spans), !id.isEmpty else { return }
            parent.onOpenComment(id)
        }
    }
}
#endif
