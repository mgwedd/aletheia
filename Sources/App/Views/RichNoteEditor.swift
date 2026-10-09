import SwiftUI
import AppKit

/// A what-you-see-is-what-you-get note editor: headings, bold, italic and
/// bulleted / numbered lists show as formatted text with a small toolbar and the
/// usual Notes shortcuts, instead of raw `##` and `**`.
///
/// The binding stays Markdown. Notes are saved as files and read by the local
/// AI as text, so the editor converts on the way in and out
/// (`NoteRichText`). Look and sizing match `EditorField`.
///
///     markdown (String) ◀──every edit──┐
///           │                          │
///     NoteRichText ──▶ NSTextView ─────┘
///           ▲  outside change only (never while typing, so the caret stays)
struct RichNoteEditor: View {
    @Binding var markdown: String
    var placeholder: String = ""
    var fonts: NoteRichText.Fonts = .sans
    var minHeight: CGFloat = 90
    /// Grow to fill the space offered instead of sizing to `minHeight`.
    var fills = false
    /// What VoiceOver calls the text area.
    var label = "Note"

    @StateObject private var controller = RichNoteEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            RichNoteTextView(markdown: $markdown, fonts: fonts, label: label, controller: controller)
                .frame(minHeight: minHeight, maxHeight: fills ? .infinity : nil)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.field, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if controller.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.muted.color)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .themeField(isFocused: controller.isFocused)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            styleMenu
            toolbarDivider
            formatButton("Bold", symbol: "bold", help: "Bold (⌘B)", active: controller.isBold) {
                controller.toggleBold()
            }
            formatButton("Italic", symbol: "italic", help: "Italic (⌘I)", active: controller.isItalic) {
                controller.toggleItalic()
            }
            toolbarDivider
            formatButton("Bulleted list", symbol: "list.bullet", help: "Bulleted list (⇧⌘7)", active: controller.block == .bullet) {
                controller.setBlock(.bullet)
            }
            formatButton("Numbered list", symbol: "list.number", help: "Numbered list (⇧⌘9)", active: controller.block == .numbered) {
                controller.setBlock(.numbered)
            }
            Spacer(minLength: 0)
        }
    }

    private var styleTitle: String {
        switch controller.block {
        case .heading: return "Heading"
        case .subheading: return "Subheading"
        case .bullet, .numbered: return "List"
        case .body, .literal: return "Body"
        }
    }

    private var styleMenu: some View {
        let selection = Binding<NoteRichText.Block>(
            get: {
                switch controller.block {
                case .heading, .subheading: return controller.block
                case .body, .bullet, .numbered, .literal: return .body
                }
            },
            set: { controller.setBlock($0) }
        )
        return Menu {
            Picker("Text style", selection: selection) {
                Text("Body").tag(NoteRichText.Block.body)
                Text("Heading").tag(NoteRichText.Block.heading)
                Text("Subheading").tag(NoteRichText.Block.subheading)
            }
            .pickerStyle(.inline)
        } label: {
            Label(styleTitle, systemImage: "textformat.size")
                .font(Theme.Typography.control)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text style: Body (⇧⌘B), Heading (⇧⌘H), Subheading (⇧⌘J)")
        .accessibilityLabel("Text style")
        .accessibilityValue(styleTitle)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Theme.line.color)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }

    private func formatButton(
        _ title: String,
        symbol: String,
        help: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(.themeIcon)
        .controlSize(.small)
        .background(
            active ? Theme.accentTint.color : Color.clear,
            in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
        )
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - Text view

private struct RichNoteTextView: NSViewRepresentable {
    @Binding var markdown: String
    let fonts: NoteRichText.Fonts
    let label: String
    let controller: RichNoteEditorController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let contentSize = scroll.contentSize
        let textView = NoteTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        // Formatted text, but a clinical record: nothing rewrites what is typed
        // (smart quotes, dashes, replacements), links aren't detected, pasted
        // styling is dropped, and no pictures come in.
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.insertionPointColor = Theme.accent.nsColor
        textView.selectedTextAttributes = [.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor]
        // 7pt plus the text container's own 5pt padding is the design's 12 × 10.
        textView.textContainerInset = NSSize(width: 7, height: 10)
        textView.setAccessibilityLabel(label)

        controller.attach(textView)
        controller.update(markdown: markdown, binding: $markdown, fonts: fonts)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? NSTextView)?.setAccessibilityLabel(label)
        controller.update(markdown: markdown, binding: $markdown, fonts: fonts)
    }
}

/// The editor's text view: plain-text paste and the Notes formatting shortcuts.
/// The shortcuts live here, not on toolbar buttons, so they only apply while
/// this field is the one being typed in.
final class NoteTextView: NSTextView {
    weak var controller: RichNoteEditorController?

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { controller?.focusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { controller?.focusChanged(false) }
        return accepted
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self, let controller else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            if key == "b" { controller.toggleBold(); return true }
            if key == "i" { controller.toggleItalic(); return true }
        } else if flags == [.command, .shift] {
            if key == "h" { controller.setBlock(.heading); return true }
            if key == "j" { controller.setBlock(.subheading); return true }
            if key == "b" { controller.setBlock(.body); return true }
            // The digit row: key codes 26 (7) and 25 (9), since Shift changes the character.
            if event.keyCode == 26 { controller.setBlock(.bullet); return true }
            if event.keyCode == 25 { controller.setBlock(.numbered); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Controller

/// Owns the editing behavior: converts to / from Markdown, keeps list markers,
/// numbering and block types valid after every edit, implements the keys that
/// differ from a plain text view (Return and Backspace in lists and headings,
/// "- " autoformat) and the toolbar actions, and publishes the formatting at
/// the caret for the toolbar.
final class RichNoteEditorController: NSObject, ObservableObject, NSTextViewDelegate {
    /// The block type at the caret, and bold / italic of the text there.
    @Published private(set) var block: NoteRichText.Block = .body
    @Published private(set) var isBold = false
    @Published private(set) var isItalic = false
    @Published private(set) var isFocused = false
    @Published private(set) var isEmpty = true

    private(set) var fonts: NoteRichText.Fonts = .sans
    private weak var textView: NoteTextView?
    private var binding: Binding<String>?
    /// The Markdown the view and the owner last agreed on: what was loaded, or
    /// what the view last wrote. Only a different value from outside replaces
    /// the text, so typing never resets the caret.
    private var syncedMarkdown: String?
    private var isReplacingContent = false
    /// The change in flight is a single typed space (the trigger for "- " and
    /// "1. " autoformat).
    private var typedSpace = false
    /// A block chosen on the empty last paragraph, which has no character to
    /// carry it until something is typed.
    private var pendingEmpty: (location: Int, block: NoteRichText.Block)?

    // MARK: Syncing with SwiftUI

    func attach(_ textView: NoteTextView) {
        self.textView = textView
        textView.controller = self
        textView.delegate = self
    }

    /// Brings the view in line with the owner's Markdown. A no-op while the
    /// owner still holds what this view last wrote.
    func update(markdown: String, binding: Binding<String>, fonts newFonts: NoteRichText.Fonts) {
        self.binding = binding
        guard let textView else { return }
        if newFonts == fonts, let synced = syncedMarkdown, Self.identical(synced, markdown) { return }
        fonts = newFonts
        replaceContent(of: textView, with: markdown)
    }

    private func replaceContent(of textView: NoteTextView, with markdown: String) {
        guard let storage = textView.textStorage else { return }
        let previous = textView.selectedRange()
        isReplacingContent = true
        defer { isReplacingContent = false }

        storage.setAttributedString(NoteRichText.attributedString(fromMarkdown: markdown, font: fonts))
        syncedMarkdown = markdown
        pendingEmpty = nil

        let length = storage.length
        let location = min(previous.location, length)
        textView.setSelectedRange(NSRange(location: location, length: min(previous.length, length - location)))
        updateTypingAttributes()
        // Old undo steps refer to text that no longer exists.
        textView.undoManager?.removeAllActions()
        publishState()
    }

    /// Code-unit equality: Swift's `==` treats canonically-equivalent strings
    /// as equal, which would let a change the editor made go unreported.
    private static func identical(_ a: String, _ b: String) -> Bool {
        a.utf16.elementsEqual(b.utf16)
    }

    private func emit(from storage: NSTextStorage) {
        let markdown = NoteRichText.markdown(from: storage)
        if let synced = syncedMarkdown, Self.identical(synced, markdown) { return }
        syncedMarkdown = markdown
        binding?.wrappedValue = markdown
    }

    func focusChanged(_ focused: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFocused != focused else { return }
            self.isFocused = focused
        }
    }

    // MARK: Published state

    private func publishState() {
        guard let textView, let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        let typing = textView.typingAttributes

        let currentBlock: NoteRichText.Block
        if selection.length == 0 {
            currentBlock = Self.block(in: typing)
        } else {
            currentBlock = NoteRichText.blockKind(at: selection.location, in: storage)
        }

        var bold = false
        var italic = false
        if currentBlock == .body || currentBlock == .bullet || currentBlock == .numbered {
            if selection.length == 0 {
                if let font = typing[.font] as? NSFont {
                    let found = NoteRichText.traits(of: font)
                    bold = found.bold
                    italic = found.italic
                }
            } else {
                let found = selectionTraits(in: storage, range: selection)
                bold = found.bold
                italic = found.italic
            }
        }
        let empty = storage.length == 0

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.block != currentBlock { self.block = currentBlock }
            if self.isBold != bold { self.isBold = bold }
            if self.isItalic != italic { self.isItalic = italic }
            if self.isEmpty != empty { self.isEmpty = empty }
        }
    }

    private static func block(in attributes: [NSAttributedString.Key: Any]) -> NoteRichText.Block {
        (attributes[NoteRichText.blockKey] as? String).flatMap(NoteRichText.Block.init(rawValue:)) ?? .body
    }

    /// Whether every formattable character in `range` is bold / italic.
    private func selectionTraits(in storage: NSTextStorage, range: NSRange) -> (bold: Bool, italic: Bool) {
        var allBold = true
        var allItalic = true
        var sawText = false
        for run in formattableRuns(in: storage, range: range) {
            sawText = true
            let found = NoteRichText.traits(of: run.font)
            if !found.bold { allBold = false }
            if !found.italic { allItalic = false }
        }
        return sawText ? (allBold, allItalic) : (false, false)
    }

    /// The runs of body and list text in `range`: not list markers, line ends
    /// or headings / literal text (whose weight isn't theirs to change).
    private func formattableRuns(in storage: NSTextStorage, range: NSRange) -> [(range: NSRange, block: NoteRichText.Block, font: NSFont)] {
        var runs: [(range: NSRange, block: NoteRichText.Block, font: NSFont)] = []
        let text = storage.string as NSString
        storage.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            if attributes[NoteRichText.markerKey] != nil { return }
            let kind = Self.block(in: attributes)
            guard kind == .body || kind == .bullet || kind == .numbered else { return }
            let piece = text.substring(with: runRange)
            if piece.unicodeScalars.allSatisfy({ CharacterSet.newlines.contains($0) }) { return }
            let font = (attributes[.font] as? NSFont) ?? self.fonts.body
            runs.append((runRange, kind, font))
        }
        return runs
    }

    // MARK: Typing attributes

    /// What the next typed character looks like: the block of the paragraph the
    /// caret is in and the font of the text before it.
    private func updateTypingAttributes() {
        guard let textView, let storage = textView.textStorage else { return }
        textView.typingAttributes = typingAttributes(at: textView.selectedRange().location, in: storage)
    }

    private func typingAttributes(at caret: Int, in storage: NSTextStorage) -> [NSAttributedString.Key: Any] {
        guard let context = paragraphContext(at: caret, in: storage) else {
            var kind = NoteRichText.Block.body
            if let pending = pendingEmpty, pending.location == min(caret, storage.length) { kind = pending.block }
            return fonts.attributes(for: kind)
        }
        var attributes = fonts.attributes(for: context.kind)
        var source: Int?
        if caret > context.contentStart && caret <= context.contentEnd {
            source = caret - 1
        } else if context.contentStart < context.contentEnd {
            source = context.contentStart
        }
        if let source, source < storage.length, let font = storage.attributes(at: source, effectiveRange: nil)[.font] {
            attributes[.font] = font
        }
        return attributes
    }

    // MARK: Paragraph helpers

    private struct ParagraphContext {
        let range: NSRange
        let kind: NoteRichText.Block
        /// First character after the list marker (the start, for other blocks).
        let contentStart: Int
        /// End of the text, before the line terminator.
        let contentEnd: Int
        let hasTerminator: Bool
    }

    /// The paragraph containing `location`, or nil for the empty last paragraph
    /// (after a final line end) and an empty document.
    private func paragraphContext(at location: Int, in storage: NSTextStorage) -> ParagraphContext? {
        let length = storage.length
        guard length > 0 else { return nil }
        let text = storage.string as NSString
        if location >= length && NoteRichText.isTerminator(text.character(at: length - 1)) { return nil }
        let range = text.paragraphRange(for: NSRange(location: max(0, min(location, length - 1)), length: 0))
        let content = NoteRichText.contentRange(ofParagraph: range, in: text)
        let marker = NoteRichText.markerRange(in: storage, paragraph: range)
        return ParagraphContext(
            range: range,
            kind: NoteRichText.blockKind(at: range.location, in: storage),
            contentStart: min(NSMaxRange(marker), NSMaxRange(content)),
            contentEnd: NSMaxRange(content),
            hasTerminator: NSMaxRange(content) < NSMaxRange(range)
        )
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        typedSpace = !isReplacingContent && affectedCharRange.length == 0 && replacementString == " "
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isReplacingContent,
              let textView = notification.object as? NSTextView,
              let storage = textView.textStorage
        else { return }

        if !textView.hasMarkedText() {
            if typedSpace {
                typedSpace = false
                applyAutoformat(in: textView)
            }
            normalize(textView)
        }
        updateTypingAttributes()
        emit(from: storage)
        publishState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if let pending = pendingEmpty, pending.location != textView.selectedRange().location {
            pendingEmpty = nil
        }
        updateTypingAttributes()
        publishState()
    }

    /// The caret never sits inside a list marker: a click or Home lands at the
    /// start of the text, and arrow-left from there goes to the previous line.
    func textView(
        _ textView: NSTextView,
        willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
        toCharacterRange newSelectedCharRange: NSRange
    ) -> NSRange {
        guard newSelectedCharRange.length == 0,
              let storage = textView.textStorage,
              newSelectedCharRange.location < storage.length,
              let context = paragraphContext(at: newSelectedCharRange.location, in: storage),
              context.kind.isList,
              newSelectedCharRange.location < context.contentStart
        else { return newSelectedCharRange }

        if NSApp.currentEvent?.type == .keyDown,
           oldSelectedCharRange.length == 0,
           oldSelectedCharRange.location == context.contentStart,
           context.range.location > 0 {
            return NSRange(location: context.range.location - 1, length: 0)
        }
        return NSRange(location: context.contentStart, length: 0)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            return handleReturn(in: textView)
        }
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            return handleBackspace(in: textView)
        }
        return false
    }

    private func normalize(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        storage.beginEditing()
        let adjusted = NoteRichText.normalize(storage, fonts: fonts, selection: selection)
        storage.endEditing()
        if adjusted != selection { textView.setSelectedRange(adjusted) }
    }

    // MARK: Return and Backspace

    /// Return in a list continues it (an empty item ends it); Return at the end
    /// of a heading starts a body paragraph. Anything else is the default.
    private func handleReturn(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        guard let context = paragraphContext(at: selection.location, in: storage) else { return false }

        switch context.kind {
        case .bullet, .numbered:
            if selection.length == 0 && context.contentStart >= context.contentEnd {
                applyBlock(.body, to: context.range, selection: selection)
                return true
            }
            let insertion = NSMutableAttributedString(string: "\n", attributes: fonts.attributes(for: context.kind))
            insertion.append(NoteRichText.markerString(for: context.kind, fonts: fonts))
            textView.insertText(insertion, replacementRange: selection)
            return true
        case .heading, .subheading:
            guard selection.length == 0, selection.location >= context.contentEnd else { return false }
            if context.hasTerminator {
                let point = NSMaxRange(context.range)
                let line = NSAttributedString(string: "\n", attributes: fonts.attributes(for: .body))
                textView.insertText(line, replacementRange: NSRange(location: point, length: 0))
                textView.setSelectedRange(NSRange(location: point, length: 0))
            } else {
                let line = NSAttributedString(string: "\n", attributes: fonts.attributes(for: context.kind))
                textView.insertText(line, replacementRange: NSRange(location: storage.length, length: 0))
            }
            return true
        case .body, .literal:
            return false
        }
    }

    /// Backspace at the start of a list item's text turns it into body text.
    private func handleBackspace(in textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return false }
        let selection = textView.selectedRange()
        guard selection.length == 0,
              let context = paragraphContext(at: selection.location, in: storage),
              context.kind.isList,
              selection.location == context.contentStart
        else { return false }
        applyBlock(.body, to: context.range, selection: selection)
        return true
    }

    // MARK: Autoformat

    /// "- " or "* " at the start of a body paragraph becomes a bullet, and
    /// "1. " a numbered item, as in Apple Notes.
    private func applyAutoformat(in textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard selection.length == 0, selection.location >= 2,
              let context = paragraphContext(at: selection.location - 1, in: storage),
              context.kind == .body
        else { return }

        let text = storage.string as NSString
        let prefixRange = NSRange(location: context.range.location, length: selection.location - context.range.location)
        guard prefixRange.length >= 2 else { return }
        let prefix = text.substring(with: prefixRange)

        let target: NoteRichText.Block
        if prefix == "- " || prefix == "* " {
            target = .bullet
        } else if prefix.count > 2, prefix.count <= 11, prefix.hasSuffix(". "),
                  prefix.dropLast(2).allSatisfy({ $0.isASCII && $0.isNumber }) {
            target = .numbered
        } else {
            return
        }
        textView.insertText(NoteRichText.markerString(for: target, fonts: fonts), replacementRange: prefixRange)
    }

    // MARK: Toolbar and shortcut actions

    /// Sets the block type of the selected paragraphs. Choosing a list type
    /// again on a list turns it back into body text.
    func setBlock(_ target: NoteRichText.Block) {
        guard let textView, let storage = textView.textStorage else { return }
        defer { focusEditor() }
        let selection = textView.selectedRange()
        let length = storage.length

        // The empty last paragraph (or an empty note) has no text to convert.
        if paragraphContext(at: selection.location, in: storage) == nil {
            if target.isList {
                textView.insertText(
                    NoteRichText.markerString(for: target, fonts: fonts),
                    replacementRange: NSRange(location: length, length: 0)
                )
            } else {
                pendingEmpty = (length, target)
                updateTypingAttributes()
                publishState()
            }
            return
        }

        let text = storage.string as NSString
        let range = text.paragraphRange(for: selection)
        var allMatch = true
        var location = range.location
        while location < NSMaxRange(range) {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            if NoteRichText.blockKind(at: paragraph.location, in: storage) != target { allMatch = false }
            location = NSMaxRange(paragraph)
        }
        if allMatch && !target.isList { return }
        applyBlock(allMatch ? .body : target, to: range, selection: selection)
    }

    /// Replaces whole paragraphs with the same text as `target`, keeping the
    /// caret at the same place in the text. One undoable edit.
    private func applyBlock(_ target: NoteRichText.Block, to range: NSRange, selection: NSRange) {
        guard let textView, let storage = textView.textStorage else { return }
        let original = storage.attributedSubstring(from: range)
        let converted = NoteRichText.converting(original, to: target, fonts: fonts)

        var offsetInText = 0
        if selection.length == 0 {
            let oldMarker = NoteRichText.markerRange(in: original, paragraph: NSRange(location: 0, length: original.length))
            offsetInText = max(0, selection.location - range.location - NSMaxRange(oldMarker))
        }

        textView.insertText(converted, replacementRange: range)

        let text = storage.string as NSString
        if selection.length == 0 {
            guard let context = paragraphContext(at: min(range.location, max(0, storage.length - 1)), in: storage),
                  range.location < storage.length else {
                textView.setSelectedRange(NSRange(location: min(range.location, storage.length), length: 0))
                return
            }
            let caret = min(context.contentStart + offsetInText, context.contentEnd)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
        } else {
            let end = min(range.location + converted.length, text.length)
            textView.setSelectedRange(NSRange(location: range.location, length: max(0, end - range.location)))
        }
    }

    func toggleBold() { toggleTrait(bold: true) }

    func toggleItalic() { toggleTrait(bold: false) }

    /// Bold / italic on the selection, or on what is typed next when there is
    /// just a caret. Off when everything selected already has it.
    private func toggleTrait(bold: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        defer { focusEditor() }
        let selection = textView.selectedRange()

        if selection.length == 0 {
            var attributes = textView.typingAttributes
            let kind = Self.block(in: attributes)
            guard kind == .body || kind == .bullet || kind == .numbered else {
                NSSound.beep()
                return
            }
            let font = (attributes[.font] as? NSFont) ?? fonts.body
            let current = NoteRichText.traits(of: font)
            attributes[.font] = fonts.font(
                for: kind,
                bold: bold ? !current.bold : current.bold,
                italic: bold ? current.italic : !current.italic
            )
            textView.typingAttributes = attributes
            publishState()
            return
        }

        let runs = formattableRuns(in: storage, range: selection)
        guard !runs.isEmpty else {
            NSSound.beep()
            return
        }
        let current = selectionTraits(in: storage, range: selection)
        let turnOn = bold ? !current.bold : !current.italic

        // Collect first: the storage can't be edited while it is enumerated.
        var changes: [(range: NSRange, font: NSFont)] = []
        for run in runs {
            let found = NoteRichText.traits(of: run.font)
            let font = fonts.font(
                for: run.block,
                bold: bold ? turnOn : found.bold,
                italic: bold ? found.italic : turnOn
            )
            changes.append((run.range, font))
        }
        guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
        storage.beginEditing()
        for change in changes {
            storage.addAttribute(.font, value: change.font, range: change.range)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private func focusEditor() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }
}
