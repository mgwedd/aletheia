import SwiftUI
import AppKit

/// An answer's prose, set as one piece of styled text, so a drag selects
/// across its paragraphs, headings, lists and quotes. Code and diagram cards
/// (and rules) stand on their own between runs of prose.
enum AnswerText {
    enum Segment: Equatable {
        /// Consecutive headings, paragraphs, lists and quotes: one selectable run.
        case prose([MarkdownBlock])
        /// A code or diagram card, or a rule.
        case card(MarkdownBlock)
    }

    static func segments(_ blocks: [MarkdownBlock]) -> [Segment] {
        var out: [Segment] = []
        var prose: [MarkdownBlock] = []
        func flush() {
            if !prose.isEmpty { out.append(.prose(prose)); prose = [] }
        }
        for block in blocks {
            switch block {
            case .code, .rule:
                flush()
                out.append(.card(block))
            case .heading, .paragraph, .bulleted, .numbered, .quote:
                prose.append(block)
            }
        }
        flush()
        return out
    }

    /// How a run of prose is set.
    struct Look: Equatable {
        var size: CGFloat
        var serif = false
        var lineSpacing: CGFloat
        var blockSpacing: CGFloat
        var listSpacing: CGFloat
        var ink: Theme.ColorToken
        var muted: Theme.ColorToken = Theme.muted
    }

    static let listIndent: CGFloat = 22
    static let quoteIndent: CGFloat = 14

    static func attributed(_ blocks: [MarkdownBlock], look: Look) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            let last = index == blocks.count - 1
            let after = last ? 0 : look.blockSpacing
            switch block {
            case let .heading(level, text):
                let style = paragraphStyle(look, before: level <= 2 && index > 0 ? 2 : 0, after: after)
                out.append(inline(text, font: headingFont(level, look: look), color: look.ink.nsColor, style: style))
            case let .paragraph(text):
                out.append(inline(text, font: font(look), color: look.ink.nsColor, style: paragraphStyle(look, after: after)))
            case let .bulleted(items):
                appendList(items.map { ("•", $0) }, to: out, look: look, after: after)
            case let .numbered(items):
                appendList(items.enumerated().map { ("\($0.offset + 1).", $0.element) }, to: out, look: look, after: after)
            case let .quote(lines):
                let style = paragraphStyle(look, indent: quoteIndent, after: after)
                out.append(inline(lines.joined(separator: "\n"), font: font(look), color: look.muted.nsColor, style: style))
            case .code, .rule:
                continue
            }
            if !last { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func appendList(_ rows: [(String, String)], to out: NSMutableAttributedString, look: Look, after: CGFloat) {
        for (index, row) in rows.enumerated() {
            let lastRow = index == rows.count - 1
            let style = NSMutableParagraphStyle()
            style.lineSpacing = look.lineSpacing
            style.firstLineHeadIndent = 4
            style.headIndent = listIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
            style.paragraphSpacing = lastRow ? after : look.listSpacing
            out.append(NSAttributedString(string: "\(row.0)\t", attributes: [
                .font: font(look).withMonospacedDigits, .foregroundColor: look.muted.nsColor, .paragraphStyle: style,
            ]))
            out.append(inline(row.1, font: font(look), color: look.ink.nsColor, style: style))
            if !lastRow { out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])) }
        }
    }

    private static func paragraphStyle(_ look: Look, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = look.lineSpacing
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        return style
    }

    static func font(_ look: Look, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: look.size, weight: weight)
        guard look.serif, let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        return NSFont(descriptor: serif, size: look.size) ?? system
    }

    /// Headings step up from the body size; the smallest is a bold label.
    static func headingFont(_ level: Int, look: Look) -> NSFont {
        switch level {
        case 1: return font(Look(size: look.size + 5, serif: look.serif, lineSpacing: 0, blockSpacing: 0, listSpacing: 0, ink: look.ink), weight: .bold)
        case 2: return font(Look(size: look.size + 2, serif: look.serif, lineSpacing: 0, blockSpacing: 0, listSpacing: 0, ink: look.ink), weight: .bold)
        case 3: return font(look, weight: .semibold)
        default: return font(look, weight: .bold)
        }
    }

    /// Bold, italic and inline code as fonts; links are kept as plain text.
    /// A string that doesn't parse (a half-streamed `**bold`) is kept as written.
    private static func inline(_ string: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        // Soft breaks stay inside the paragraph, so its style holds.
        let soft = string.replacingOccurrences(of: "\n", with: "\u{2028}")
        guard let parsed = SafeMarkdown.attributed(from: soft) else {
            return NSAttributedString(string: soft, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                } else {
                    var traits = font.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            out.append(NSAttributedString(
                string: String(parsed[run.range].characters),
                attributes: [.font: runFont, .foregroundColor: color, .paragraphStyle: style]
            ))
        }
        return out
    }
}

private extension NSFont {
    var withMonospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// A read-only, selectable run of an answer's prose, as tall as its text.
struct AnswerTextView: NSViewRepresentable {
    let blocks: [MarkdownBlock]
    let look: AnswerText.Look

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnswerNSTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let view = AnswerNSTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.usesFontPanel = false
        view.selectedTextAttributes = [.backgroundColor: Theme.accentTint.nsColor, .foregroundColor: Theme.text.nsColor]
        view.setAccessibilityIdentifier("chat.answer-text")
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ view: AnswerNSTextView, context: Context) {
        apply(to: view, context: context)
    }

    /// Measured on the coordinator's own copy of the text, never the view's:
    /// SwiftUI asks for sizes at widths it then doesn't use, and laying the
    /// view's own text out at one of those left it wrapped to that width (a
    /// narrow column) and drawn past its frame over what sits below it.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: AnswerNSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 640
        guard width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: context.coordinator.measure.height(atWidth: width))
    }

    private func apply(to view: AnswerNSTextView, context: Context) {
        let key = Coordinator.Key(blocks: blocks, look: look)
        guard context.coordinator.applied != key else { return }
        context.coordinator.applied = key
        let text = AnswerText.attributed(blocks, look: look)
        view.textStorage?.setAttributedString(text)
        context.coordinator.measure.storage.setAttributedString(text)
        view.invalidateIntrinsicContentSize()
    }

    final class Coordinator {
        struct Key: Equatable {
            let blocks: [MarkdownBlock]
            let look: AnswerText.Look
        }
        var applied: Key?
        let measure = TextMeasure()
    }
}

/// Lays text out at any width to find its height, apart from the view that
/// shows it.
final class TextMeasure {
    let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }

    func height(atWidth width: CGFloat) -> CGFloat {
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}

/// Copy and drag of an answer stay on this Mac and out of clipboard history.
final class AnswerNSTextView: PatientTextView {
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        PHIPasteboard.writeSelection(to: pboard, kind: .copiedChat) { super.writeSelection(to: $0, types: types) }
    }
}
