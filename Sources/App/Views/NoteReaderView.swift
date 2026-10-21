import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The generated note reader text view: renders Markdown progress notes in
/// formatted serif type with Google-Docs-style margin comment highlights in place.
///
///  - Read-only while viewing, selectable so the therapist can select text to comment.
///  - Highlighting is handled via `TranscriptHighlighter.spans` directly on the
///    rendered rich text storage, keeping comment spans and clicks synchronized.
///  - Clicking a highlighted passage opens/focuses the corresponding comment in the rail.
///  - Tapping a card in the comment rail scrolls to and flashes the highlighted passage.
///  - Reports `selection` and `selectionRange` so the toolbar's "Comment on selection"
///    button can enable and anchor an inline composer card.
#if canImport(AppKit)
struct NoteReaderView: NSViewRepresentable {
    let text: String
    /// (comment id, quoted passage, quote start) triples for active comments on this note format.
    let comments: [TranscriptHighlighter.Anchor]
    @Binding var selection: String
    @Binding var selectionRange: NSRange?
    var onOpenComment: (String) -> Void = { _ in }
    var focusedCommentID: String? = nil
    var focusToken: Int = 0
    var composingRange: NSRange? = nil
    var onComposingRectChange: (CGRect?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

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

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent.nsColor
        textView.selectedTextAttributes = [.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor]
        textView.textContainerInset = NSSize(width: 19, height: 14)
        textView.delegate = context.coordinator
        textView.onPlainClick = { [weak coordinator = context.coordinator] index in
            coordinator?.handleClick(at: index)
        }

        context.coordinator.textView = textView
        scroll.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.viewportChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.viewportChanged(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )

        context.coordinator.sync(into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.sync(into: textView)
        context.coordinator.flashIfNeeded(in: textView, focusedCommentID: focusedCommentID, focusToken: focusToken)
        context.coordinator.updateComposing(in: textView, composingRange: composingRange)
    }

    final class ClickReportingTextView: NSTextView {
        var onPlainClick: ((Int) -> Void)?

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            guard event.clickCount == 1, selectedRange().length == 0 else { return }
            onPlainClick?(selectedRange().location)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteReaderView
        weak var textView: NSTextView?
        private var appliedText: String?
        private var appliedAnchorsSignature: Int?
        private var lastFlashedToken: Int?
        private var spans: [TranscriptHighlighter.Span] = []
        private var appliedComposingRange: NSRange?
        private var lastReportedRect: CGRect?
        private var isApplyingProgrammaticChange = false

        init(_ parent: NoteReaderView) { self.parent = parent }

        func sync(into textView: NSTextView) {
            let textChanged = parent.text != appliedText
            let anchorsChanged = Self.signature(of: parent.comments) != appliedAnchorsSignature
            if textChanged || anchorsChanged {
                applyFormattedContent(to: textView)
            }
        }

        private func applyFormattedContent(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            appliedText = parent.text
            appliedAnchorsSignature = Self.signature(of: parent.comments)

            let formatted = NoteRichText.attributedString(fromMarkdown: parent.text, font: .serif)
            spans = TranscriptHighlighter.spans(in: formatted.string, comments: parent.comments)

            isApplyingProgrammaticChange = true
            defer { isApplyingProgrammaticChange = false }

            storage.beginEditing()
            storage.setAttributedString(formatted)

            let highlight = Theme.highlight.nsColor
            let highlightInk = Theme.highlightInk.nsColor
            let layers = spans.enumerated().sorted { a, b in
                a.element.range.length != b.element.range.length
                    ? a.element.range.length > b.element.range.length
                    : a.offset < b.offset
            }.map { $0.element }

            for span in layers where NSMaxRange(span.range) <= storage.length {
                storage.addAttributes([.backgroundColor: highlight, .foregroundColor: highlightInk], range: span.range)
            }
            if let composing = appliedComposingRange, NSMaxRange(composing) <= storage.length {
                storage.addAttributes([.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor], range: composing)
            }
            storage.endEditing()
        }

        func updateComposing(in textView: NSTextView, composingRange: NSRange?) {
            guard composingRange != appliedComposingRange else {
                reportComposingRect(for: textView)
                return
            }
            appliedComposingRange = composingRange
            applyFormattedContent(to: textView)
            if let range = composingRange {
                isApplyingProgrammaticChange = true
                textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                isApplyingProgrammaticChange = false
                textView.scrollRangeToVisible(range)
            }
            reportComposingRect(for: textView)
        }

        func flashIfNeeded(in textView: NSTextView, focusedCommentID: String?, focusToken: Int) {
            guard focusToken != lastFlashedToken, let targetID = focusedCommentID else { return }
            lastFlashedToken = focusToken
            guard let span = spans.first(where: { $0.commentID == targetID }),
                  let layoutManager = textView.layoutManager,
                  NSMaxRange(span.range) <= (textView.textStorage?.length ?? 0) else { return }

            textView.scrollRangeToVisible(span.range)
            let flashAttrs: [NSAttributedString.Key: Any] = [.backgroundColor: Theme.accentTint.nsColor]
            layoutManager.setTemporaryAttributes(flashAttrs, forCharacterRange: span.range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak layoutManager] in
                layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: span.range)
            }
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
                DispatchQueue.main.async(execute: publish)
            } else {
                publish()
            }
        }

        func handleClick(at index: Int) {
            guard let id = TranscriptHighlighter.commentID(at: index, in: spans), !id.isEmpty else { return }
            parent.onOpenComment(id)
        }

        @objc func viewportChanged(_ notification: Notification) {
            guard let textView else { return }
            reportComposingRect(for: textView)
        }

        private func composingRect(in textView: NSTextView) -> CGRect? {
            guard
                let range = appliedComposingRange,
                let layoutManager = textView.layoutManager,
                let clip = textView.enclosingScrollView?.contentView
            else { return nil }
            layoutManager.ensureLayout(forCharacterRange: range)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return nil }
            var line = layoutManager.lineFragmentUsedRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
            let origin = textView.textContainerOrigin
            line.origin.x += origin.x
            line.origin.y += origin.y
            let inClip = textView.convert(line, to: clip)
            return inClip.offsetBy(dx: -clip.bounds.origin.x, dy: -clip.bounds.origin.y)
        }

        private func reportComposingRect(for textView: NSTextView) {
            let rect = composingRect(in: textView).map { $0.integral }
            guard rect != lastReportedRect else { return }
            lastReportedRect = rect
            DispatchQueue.main.async { [weak self] in self?.parent.onComposingRectChange(rect) }
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
    }
}
#endif
