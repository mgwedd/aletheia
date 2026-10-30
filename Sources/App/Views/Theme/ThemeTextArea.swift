import SwiftUI
import AppKit

/// The one multi-line text input: the chat composers, comment editors, the
/// profile and settings editors, the prompt editor.
///
/// It wraps an `NSTextView` rather than `TextEditor` so the placeholder and the
/// caret share one origin. `TextEditor` insets its text by an amount SwiftUI
/// doesn't document and that differs between macOS releases, so a placeholder
/// overlaid in a SwiftUI `Text` drifts away from the caret. Here the text view
/// draws its own placeholder at `ThemeTextAreaMetrics.textOrigin`, which is
/// where the first character and the caret go, in the same font and paragraph
/// style as typed text.
///
/// The box (field fill, hairline border, accent border while focused) comes
/// from `themeField`; every color comes from `Theme`.
struct ThemeTextArea: View {
    /// How tall the box is.
    enum Height: Equatable {
        /// Fits its text between `min` and `max`, then scrolls (a chat composer).
        case grows(min: CGFloat, max: CGFloat)
        /// Takes the height offered, at least `min`; the text scrolls inside.
        case flexible(min: CGFloat)
    }

    enum Face: Equatable {
        case body
        /// For instructions that are read as code.
        case monospaced
    }

    /// Where the caret goes when the field takes focus on appear.
    enum Autofocus: Equatable {
        case none
        case caretAtEnd
    }

    @Binding var text: String
    var placeholder: String = ""
    var height: Height = .flexible(min: 90)
    var face: Face = .body
    var accessibilityLabel: String?
    /// Return calls this instead of inserting a line (Shift or Option with
    /// Return still adds one unless `modifiedReturnSubmits`). Nil leaves Return as a newline.
    var onSubmit: (() -> Void)?
    /// Esc calls this; return true when it was used, so Esc keeps its other
    /// meanings (closing a sheet) when it isn't.
    var onEscape: (() -> Bool)?
    /// Shift or Option with Return submits too, so no key makes a line break
    /// (a one-paragraph field such as a chat question).
    var modifiedReturnSubmits = false
    /// Tab moves focus to the next control instead of typing a tab character.
    var tabMovesFocus = false
    /// Room kept clear on the right for icons drawn over the box: lines wrap
    /// before it and the placeholder stops at it.
    var trailingInset: CGFloat = 0
    var autofocus: Autofocus = .none
    /// Optional two-way focus state; the field also draws its own focus border.
    var isFocused: Binding<Bool>?

    @State private var ownFocus = false

    private var focus: Binding<Bool> { isFocused ?? $ownFocus }

    var body: some View {
        ThemeTextAreaRepresentable(
            text: $text,
            placeholder: placeholder,
            height: height,
            face: face,
            accessibilityLabel: accessibilityLabel ?? (placeholder.isEmpty ? nil : placeholder),
            onSubmit: onSubmit,
            onEscape: onEscape,
            modifiedReturnSubmits: modifiedReturnSubmits,
            tabMovesFocus: tabMovesFocus,
            trailingInset: trailingInset,
            autofocus: autofocus,
            isFocused: focus
        )
        .themeField(isFocused: focus.wrappedValue)
    }
}

// MARK: - Metrics

/// The geometry that keeps the placeholder on the caret. Pure values, so the
/// alignment is unit-tested.
enum ThemeTextAreaMetrics {
    /// Design padding between the box and the text: 12 across, 10 down.
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    /// The text container's own left and right padding (`NSTextContainer`'s
    /// default), which the text view adds inside its inset.
    static let lineFragmentPadding: CGFloat = 5
    static let lineSpacing: CGFloat = 4

    /// What goes in `textContainerInset`: the design padding less the
    /// container's own.
    static var textContainerInset: NSSize {
        NSSize(width: horizontalPadding - lineFragmentPadding, height: verticalPadding)
    }

    /// Where the first character (and the caret in an empty field) is drawn,
    /// in the text view's coordinates.
    static var textOrigin: NSPoint {
        NSPoint(x: textContainerInset.width + lineFragmentPadding, y: textContainerInset.height)
    }

    /// The width lines wrap at in a view `viewWidth` wide: the box less its
    /// padding on both sides and the room kept for trailing icons.
    static func containerWidth(forViewWidth viewWidth: CGFloat, trailingInset: CGFloat) -> CGFloat {
        max(1, viewWidth - 2 * textContainerInset.width - max(0, trailingInset))
    }

    static func font(for face: ThemeTextArea.Face) -> NSFont {
        switch face {
        case .body: return NSFont.systemFont(ofSize: 14)
        case .monospaced: return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        return style
    }

    /// Text and placeholder share these but for color.
    static func attributes(face: ThemeTextArea.Face, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font(for: face), .foregroundColor: color, .paragraphStyle: paragraphStyle()]
    }

    /// The height that fits `lineCount` lines of `face`, box padding included.
    static func height(forContentHeight content: CGFloat) -> CGFloat {
        content + 2 * verticalPadding
    }
}

// MARK: - Text view

/// An `NSTextView` that draws its placeholder where the text goes, sends Return
/// to `onSubmit`, and reports focus.
final class ThemeTextAreaTextView: PatientTextView {
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        PHIPasteboard.writeSelection(to: pboard, kind: .copiedPatientText) { super.writeSelection(to: $0, types: types) }
    }

    var placeholder = "" { didSet { if placeholder != oldValue { needsDisplay = true } } }
    var face: ThemeTextArea.Face = .body
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Bool)?
    var modifiedReturnSubmits = false
    var tabMovesFocus = false
    var onFocusChange: ((Bool) -> Void)?
    /// See `ThemeTextArea.trailingInset`. The container's width is managed here
    /// (it does not track the view) so the reservation survives resizing.
    var trailingInset: CGFloat = 0 {
        didSet { if trailingInset != oldValue { updateContainerWidth() } }
    }

    private func updateContainerWidth() {
        guard let container = textContainer else { return }
        let width = ThemeTextAreaMetrics.containerWidth(forViewWidth: frame.width, trailingInset: trailingInset)
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            needsDisplay = true
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.001
        super.setFrameSize(newSize)
        if widthChanged {
            updateContainerWidth()
        }
    }

    /// The placeholder's attributes: the typed text's, in the muted color.
    var placeholderAttributes: [NSAttributedString.Key: Any] {
        ThemeTextAreaMetrics.attributes(face: face, color: Theme.muted.nsColor)
    }

    /// Top-left of the placeholder, in this view's coordinates. The text
    /// container's origin plus its line-fragment padding: the same point the
    /// layout manager starts the first line at.
    var placeholderOrigin: NSPoint {
        NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
    }

    var showsPlaceholder: Bool { string.isEmpty && !placeholder.isEmpty }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsPlaceholder else { return }
        let width = max(1, (textContainer?.containerSize.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 0))
        NSAttributedString(string: placeholder, attributes: placeholderAttributes)
            .draw(with: NSRect(origin: placeholderOrigin, size: NSSize(width: width, height: 10_000)), options: [.usesLineFragmentOrigin])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        // 53 is Escape.
        if event.keyCode == 53, let onEscape, onEscape() { return }
        // 36 is Return, 76 the keypad Enter.
        if let onSubmit, isEditable, event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            let flags = event.modifierFlags
            if modifiedReturnSubmits || !(flags.contains(.shift) || flags.contains(.option)) {
                onSubmit()
            } else {
                insertNewlineIgnoringFieldEditor(nil)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        if tabMovesFocus { window?.selectNextKeyView(self) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if tabMovesFocus { window?.selectPreviousKeyView(self) } else { super.insertBacktab(sender) }
    }

    /// Re-applies the theme's font, colors and paragraph style to the whole
    /// text and to what is typed next.
    func applyStyle() {
        let attributes = ThemeTextAreaMetrics.attributes(face: face, color: Theme.text.nsColor)
        font = ThemeTextAreaMetrics.font(for: face)
        textColor = Theme.text.nsColor
        defaultParagraphStyle = ThemeTextAreaMetrics.paragraphStyle()
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        insertionPointColor = Theme.accent.nsColor
        selectedTextAttributes = [.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor]
    }

    /// The height the text needs at `width`, padding included, never less than one line.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        let targetWidth = ThemeTextAreaMetrics.containerWidth(forViewWidth: width, trailingInset: trailingInset)
        if abs(targetWidth - container.containerSize.width) < 0.001 {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            let oneLine = layout.defaultLineHeight(for: ThemeTextAreaMetrics.font(for: face)) + ThemeTextAreaMetrics.lineSpacing
            let extra = layout.extraLineFragmentRect
            let text = max(used.height, extra.isEmpty ? 0 : extra.maxY, oneLine)
            return ThemeTextAreaMetrics.height(forContentHeight: text)
        }

        // SwiftUI asks for the same few widths many times in one layout pass;
        // building a text system for each answer made a long pass take minutes.
        if measured.text != string || measured.face != face { measured = (string, face, [:]) }
        if let height = measured.heights[targetWidth] { return height }

        // Measure on a dedicated offscreen container so the live container's
        // geometry is never mutated during a layout pass, which would trigger
        // a layout invalidation liveloop.
        let storage = NSTextStorage(string: string, attributes: ThemeTextAreaMetrics.attributes(face: face, color: Theme.text.nsColor))
        let measureLayout = NSLayoutManager()
        let measureContainer = NSTextContainer(containerSize: NSSize(width: targetWidth, height: .greatestFiniteMagnitude))
        measureContainer.lineFragmentPadding = ThemeTextAreaMetrics.lineFragmentPadding
        measureLayout.addTextContainer(measureContainer)
        storage.addLayoutManager(measureLayout)
        measureLayout.ensureLayout(for: measureContainer)
        let used = measureLayout.usedRect(for: measureContainer)
        let oneLine = measureLayout.defaultLineHeight(for: ThemeTextAreaMetrics.font(for: face)) + ThemeTextAreaMetrics.lineSpacing
        let extra = measureLayout.extraLineFragmentRect
        let text = max(used.height, extra.isEmpty ? 0 : extra.maxY, oneLine)
        let height = ThemeTextAreaMetrics.height(forContentHeight: text)
        if measured.heights.count >= 16 { measured.heights.removeAll() }
        measured.heights[targetWidth] = height
        return height
    }

    /// Offscreen heights by container width, for `measured.text` in `measured.face`.
    private var measured: (text: String, face: ThemeTextArea.Face, heights: [CGFloat: CGFloat]) = ("", .body, [:])
}

// MARK: - Representable

private struct ThemeTextAreaRepresentable: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let height: ThemeTextArea.Height
    let face: ThemeTextArea.Face
    let accessibilityLabel: String?
    let onSubmit: (() -> Void)?
    let onEscape: (() -> Bool)?
    let modifiedReturnSubmits: Bool
    let tabMovesFocus: Bool
    let trailingInset: CGFloat
    let autofocus: ThemeTextArea.Autofocus
    @Binding var isFocused: Bool

    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let contentSize = scroll.contentSize
        let textView = ThemeTextAreaTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = ThemeTextAreaMetrics.lineFragmentPadding
        textView.textContainerInset = ThemeTextAreaMetrics.textContainerInset
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.delegate = context.coordinator
        scroll.documentView = textView

        textView.face = face
        textView.applyStyle()
        textView.string = text
        textView.applyStyle()
        context.coordinator.configure(textView, with: self)

        if autofocus == .caretAtEnd {
            // The window needs a beat to become key before focus sticks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak textView] in
                guard let textView, let window = textView.window else { return }
                window.makeFirstResponder(textView)
                CaretPlacement.moveToEnd(in: textView)
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ThemeTextAreaTextView else { return }
        context.coordinator.parent = self
        context.coordinator.configure(textView, with: self)

        if textView.face != face {
            textView.face = face
            textView.applyStyle()
        }
        if textView.string != text, !textView.hasMarkedText() {
            textView.string = text
            textView.applyStyle()
        }

        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        scroll.alphaValue = isEnabled ? 1 : 0.55

        // Drive focus from the binding when programmatic focus is requested.
        let isFirstResponder = textView.window?.firstResponder === textView
        if isFocused, !isFirstResponder, isEnabled, let window = textView.window {
            DispatchQueue.main.async { window.makeFirstResponder(textView) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        switch height {
        case let .flexible(min):
            return CGSize(width: width, height: max(min, proposal.height ?? min))
        case let .grows(min, max):
            guard let textView = scroll.documentView as? ThemeTextAreaTextView else {
                return CGSize(width: width, height: min)
            }
            let fitted = textView.contentHeight(forWidth: width)
            return CGSize(width: width, height: Swift.min(max, Swift.max(min, fitted)))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ThemeTextAreaRepresentable

        init(_ parent: ThemeTextAreaRepresentable) { self.parent = parent }

        func configure(_ textView: ThemeTextAreaTextView, with representable: ThemeTextAreaRepresentable) {
            textView.placeholder = representable.placeholder
            textView.onSubmit = representable.onSubmit
            textView.onEscape = representable.onEscape
            textView.modifiedReturnSubmits = representable.modifiedReturnSubmits
            textView.tabMovesFocus = representable.tabMovesFocus
            textView.trailingInset = representable.trailingInset
            textView.setAccessibilityLabel(representable.accessibilityLabel)
            textView.onFocusChange = { [weak self] focused in
                guard let self else { return }
                DispatchQueue.main.async {
                    if self.parent.isFocused != focused { self.parent.isFocused = focused }
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }
    }
}
