import SwiftUI
#if canImport(AppKit)
import AppKit
import CoreText
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
///    selection is just a caret), so the floating comment button can show
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
    /// When set, this is scrolled into view and briefly flashed: the passage a
    /// comment anchors to (the "click a card in the rail → jump to the text"
    /// direction of the Google-Docs two-way focus), or a search match. Cleared
    /// by the owner.
    var focus: TranscriptFocus? = nil
    /// Bumped by the owner on every focus request (a card or highlight click,
    /// a search hit opened). The scroll-and-flash fires whenever this changes,
    /// even if `focus` is the same as last time, so clicking the same card
    /// again after scrolling away jumps back to its passage.
    var focusToken: Int = 0
    /// The passage a comment is being written for (UTF-16, in this view's text).
    /// While set, the passage is shown highlighted and scrolled into view, the
    /// caret is cleared so nothing competes with the highlight, and
    /// `onComposingRectChange` reports where the passage's last line sits.
    var composingRange: NSRange? = nil
    /// The last line of `composingRange` in this view's own visible area
    /// (top-left origin, so it can be used directly by a SwiftUI overlay on this
    /// view). Reported again as the text scrolls or re-wraps; nil when there is
    /// no passage or it can't be placed.
    var onComposingRectChange: (CGRect?) -> Void = { _ in }
    /// The first line of the current selection in this view's own visible area
    /// (top-left origin, like `onComposingRectChange`). Reported as the
    /// selection changes and as the text scrolls or re-wraps; nil for a caret.
    /// It anchors the floating comment button.
    var onSelectionRectChange: (CGRect?) -> Void = { _ in }
    /// Shown in place of the "Call audio" label: the patient's first name.
    /// Display only; the stored transcript keeps "Call audio". Empty shows
    /// the label as stored.
    var callAudioName: String = ""

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

        context.coordinator.textView = textView
        textView.layoutManager?.delegate = context.coordinator
        // Tell the coordinator when the visible area moves or the text re-wraps,
        // so a composer anchored under a passage follows it.
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
        let renamed = context.coordinator.parent.callAudioName != callAudioName
        context.coordinator.parent = self
        textView.isEditable = isEditable
        (textView as? ClickReportingTextView)?.callAudioName = callAudioName
        if renamed { context.coordinator.restyle(textView) }
        // Only touch the view when the text or the set of comment anchors
        // actually changed; rebuilding on every SwiftUI pass would clobber the
        // user's caret and selection.
        context.coordinator.sync(into: textView)
        context.coordinator.flashIfNeeded(in: textView, focus: focus, focusToken: focusToken)
        context.coordinator.syncComposing(in: textView)
    }

    /// An `NSTextView` that reports a plain click (single click, no drag, so an
    /// empty selection) with the caret position it landed on. Used instead of the
    /// `.link` attribute, which in an editable text view doesn't reliably fire on
    /// a simple click.
    final class ClickReportingTextView: PatientTextView {
        var onPlainClick: ((Int) -> Void)?
        /// See `TranscriptTextView.callAudioName`.
        var callAudioName = ""
        /// Copy and drag take the text as it is on screen: call audio named,
        /// no hidden " (overlapping)" labels. The view is plain text, so there is no RTF.
        override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
            let ok = super.writeSelection(to: pboard, types: types)
            guard ok else { return ok }
            if let text = pboard.string(forType: .string) {
                pboard.setString(TranscriptStyler.forReader(text, callAudioName: callAudioName), forType: .string)
            }
            return ok
        }

        // VoiceOver reads the transcript as it is on screen.
        override func accessibilityValue() -> String? {
            super.accessibilityValue().map { TranscriptStyler.forReader($0, callAudioName: callAudioName) }
        }

        override func accessibilityString(for range: NSRange) -> String? {
            super.accessibilityString(for: range).map { TranscriptStyler.forReader($0, callAudioName: callAudioName) }
        }

        override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
            super.accessibilityAttributedString(for: range).map { TranscriptStyler.forReader($0, callAudioName: callAudioName) }
        }

        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event) // runs the whole press-drag-release
            guard event.clickCount == 1, selectedRange().length == 0 else { return }
            onPlainClick?(selectedRange().location)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        /// Marks characters that stay in the stored text but are not drawn.
        static let hiddenKey = NSAttributedString.Key("aletheia.hiddenOverlapLabel")
        /// On a call-audio label: the name drawn in its place.
        static let displayNameKey = NSAttributedString.Key("aletheia.callAudioDisplayName")
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
            case .overlapTag:
                // Kept in the text (offsets and the model hint depend on it) but
                // laid out as zero-width null glyphs; see `layoutManager(_:shouldGenerateGlyphs:...)`.
                return [Coordinator.hiddenKey: true]
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

        // MARK: Hidden characters

        /// Replaces the glyphs of hidden characters with null glyphs: no width,
        /// nothing drawn, but the characters (and so every offset) stay put. A
        /// call-audio label is laid out as the name instead: the name's glyphs
        /// all belong to the label's first character, and the label's own
        /// characters become null glyphs.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes charIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            guard let storage = layoutManager.textStorage else { return 0 }
            var outGlyphs: [CGGlyph] = []
            var outProps: [NSLayoutManager.GlyphProperty] = []
            var outIndexes: [Int] = []
            var changed = false
            var lastNamed = -1
            for i in 0..<glyphRange.length {
                let index = charIndexes[i]
                guard index < storage.length else {
                    outGlyphs.append(glyphs[i]); outProps.append(props[i]); outIndexes.append(index)
                    continue
                }
                var label = NSRange()
                if let name = storage.attribute(Self.displayNameKey, at: index, effectiveRange: &label) as? String {
                    changed = true
                    if index == label.location, lastNamed != index {
                        lastNamed = index
                        let units = Array(name.utf16)
                        var named = [CGGlyph](repeating: 0, count: units.count)
                        CTFontGetGlyphsForCharacters(font as CTFont, units, &named, units.count)
                        for glyph in named where glyph != 0 {
                            outGlyphs.append(glyph); outProps.append([]); outIndexes.append(index)
                        }
                    } else {
                        outGlyphs.append(glyphs[i]); outProps.append(.null); outIndexes.append(index)
                    }
                } else if storage.attribute(Self.hiddenKey, at: index, effectiveRange: nil) != nil {
                    changed = true
                    outGlyphs.append(glyphs[i]); outProps.append(.null); outIndexes.append(index)
                } else {
                    outGlyphs.append(glyphs[i]); outProps.append(props[i]); outIndexes.append(index)
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(
                outGlyphs, properties: outProps, characterIndexes: outIndexes, font: font,
                forGlyphRange: NSRange(location: glyphRange.location, length: outGlyphs.count)
            )
            return outGlyphs.count
        }

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
        /// Repaints the styling after the call-audio name changed.
        func restyle(_ textView: NSTextView) { applyHighlights(to: textView) }

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
                if case let .speaker(label) = styled.role, !parent.callAudioName.isEmpty,
                   TranscriptStyler.tone(for: label) == .callAudio {
                    storage.addAttribute(Self.displayNameKey, value: parent.callAudioName, range: styled.range)
                }
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
        func flashIfNeeded(in textView: NSTextView, focus: TranscriptFocus?, focusToken: Int) {
            guard TranscriptHighlighter.isNewFocusRequest(
                focus, token: focusToken, lastHandledToken: lastFlashedToken
            ), let focus else {
                if focus == nil { lastFlashedToken = nil }
                return
            }
            lastFlashedToken = focusToken
            guard
                let range = TranscriptHighlighter.range(
                    for: focus, spans: spans, length: (textView.string as NSString).length
                ),
                let layoutManager = textView.layoutManager
            else { return }

            textView.scrollRangeToVisible(range)
            let flash = Theme.accentTint.nsColor
            layoutManager.addTemporaryAttributes([.backgroundColor: flash], forCharacterRange: range)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak layoutManager] in
                layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
        }

        // MARK: Composing (highlight, scroll, anchor rect)

        /// The passage the composing highlight was last applied to.
        private var appliedComposingRange: NSRange?
        private var lastReportedRect: CGRect?
        weak var textView: NSTextView?

        /// Keeps the composing highlight, scroll position and reported anchor in
        /// line with the owner's `composingRange`. Cheap when nothing changed.
        func syncComposing(in textView: NSTextView) {
            self.textView = textView
            let length = (textView.string as NSString).length
            var target = parent.composingRange
            if let range = target, range.length == 0 || NSMaxRange(range) > length { target = nil }

            if target != appliedComposingRange {
                if let layoutManager = textView.layoutManager {
                    if let old = appliedComposingRange, NSMaxRange(old) <= length {
                        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: old)
                        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
                    }
                    if let range = target {
                        layoutManager.addTemporaryAttributes(
                            [.backgroundColor: Theme.highlight.nsColor, .foregroundColor: Theme.highlightInk.nsColor],
                            forCharacterRange: range
                        )
                    }
                }
                appliedComposingRange = target
                if let range = target {
                    // The passage is shown highlighted instead of selected: drop
                    // the selection to a caret after it, and bring it into view.
                    isApplyingProgrammaticChange = true
                    textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
                    isApplyingProgrammaticChange = false
                    textView.scrollRangeToVisible(range)
                }
            }
            reportComposingRect(for: textView)
            reportSelectionRect(for: textView)
        }

        @objc func viewportChanged(_ notification: Notification) {
            guard let textView else { return }
            reportComposingRect(for: textView)
            reportSelectionRect(for: textView)
        }

        private var lastReportedSelectionRect: CGRect?

        /// The selection's first line in the scroll view's visible area,
        /// top-left origin (nil for a caret).
        private func reportSelectionRect(for textView: NSTextView) {
            var rect: CGRect?
            let range = textView.selectedRange()
            if range.length > 0,
               let clip = textView.enclosingScrollView?.contentView,
               let line = TranscriptSelectionGeometry.firstLineRect(of: range, in: textView) {
                let inClip = textView.convert(line, to: clip)
                rect = inClip.offsetBy(dx: -clip.bounds.origin.x, dy: -clip.bounds.origin.y).integral
            }
            guard rect != lastReportedSelectionRect else { return }
            lastReportedSelectionRect = rect
            // Deferred for the same reason as the composing rect: this can run
            // inside a SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in self?.parent.onSelectionRectChange(rect) }
        }

        /// The last line of the composing passage in the scroll view's visible
        /// area, top-left origin.
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
            // The clip view is flipped like its document view, so this is
            // top-left. Its bounds origin is the scroll offset; subtract it to
            // get the position within the visible area.
            let inClip = textView.convert(line, to: clip)
            return inClip.offsetBy(dx: -clip.bounds.origin.x, dy: -clip.bounds.origin.y)
        }

        private func reportComposingRect(for textView: NSTextView) {
            let rect = composingRect(in: textView).map { $0.integral }
            guard rect != lastReportedRect else { return }
            lastReportedRect = rect
            // Always deferred: this can run inside a SwiftUI update pass (or a
            // scroll that one triggered), where the owner's state can't be written.
            DispatchQueue.main.async { [weak self] in self?.parent.onComposingRectChange(rect) }
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
            reportSelectionRect(for: textView)
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

#if canImport(AppKit)
/// Where a selection sits in a text view, kept apart from the coordinator so it
/// can be checked against a real `NSTextView` without a window.
enum TranscriptSelectionGeometry {
    /// The part of `range` on its first line, in `textView`'s own coordinates
    /// (text container origin included). Nil for an empty or out-of-range
    /// selection.
    static func firstLineRect(of range: NSRange, in textView: NSTextView) -> CGRect? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return nil }
        let length = (textView.string as NSString).length
        guard range.length > 0, NSMaxRange(range) <= length else { return nil }
        layoutManager.ensureLayout(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        var lineGlyphs = NSRange()
        _ = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: &lineGlyphs)
        let first = NSIntersectionRange(glyphs, lineGlyphs)
        guard first.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: first, in: container)
        let origin = textView.textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }
}
#endif
