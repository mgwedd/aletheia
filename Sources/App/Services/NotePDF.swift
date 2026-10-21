import AppKit

/// Renders Markdown as print-styled text, as a paginated PDF, entirely on this
/// Mac: black serif text on white, US Letter, headings, lists, quotes and code.
/// The same styled text is what the Word export, and the rich-text copy, are
/// made from. Pure of any file or window access, so the output is unit tested
/// directly; saving goes through `FileSaver`.
enum NotePDF {
    static let paper = NSSize(width: 612, height: 792)
    static let margin: CGFloat = 54
    static var textWidth: CGFloat { paper.width - 2 * margin }

    // MARK: - Styled text

    /// The note as styled text: `title` and `subtitle` as a header (each left
    /// out when empty), then the Markdown blocks.
    static func attributedText(markdown: String, title: String, subtitle: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if !title.isEmpty {
            out.append(line(title, font: serif(18, bold: true), color: .black, after: 2))
        }
        if !subtitle.isEmpty {
            out.append(line(subtitle, font: serif(10), color: .darkGray, after: 14))
        }

        let blocks = MarkdownParser.parse(MarkdownTextStyle.note.prepared(markdown))
        for block in blocks {
            switch block {
            case let .heading(level, text):
                let size: CGFloat = level <= 1 ? 15 : level == 2 ? 13 : 11.5
                out.append(paragraph(text, font: serif(size, bold: true), before: 8, after: 3))
            case let .paragraph(text):
                out.append(paragraph(text, font: serif(11), after: 7))
            case let .bulleted(items):
                for item in items { out.append(listItem(marker: "•", text: item)) }
            case let .numbered(items):
                for (index, item) in items.enumerated() { out.append(listItem(marker: "\(index + 1).", text: item)) }
            case let .quote(lines):
                out.append(paragraph(lines.joined(separator: "\n"), font: serif(11, italic: true), color: .darkGray, indent: 16, after: 7))
            case let .code(_, code):
                let mono = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
                out.append(line(code, font: mono, color: .black, after: 7, indent: 8, background: NSColor(white: 0.94, alpha: 1)))
            case .rule:
                out.append(line(String(repeating: "─", count: 48), font: serif(8), color: .lightGray, after: 7))
            }
        }
        return out
    }

    private static func listItem(marker: String, text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 4
        style.headIndent = 22
        style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
        style.paragraphSpacing = 3
        let out = NSMutableAttributedString(
            string: "\(marker)\t",
            attributes: [.font: serif(11), .foregroundColor: NSColor.black, .paragraphStyle: style]
        )
        out.append(inline(text, font: serif(11), color: .black, style: style))
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        return out
    }

    private static func paragraph(
        _ text: String, font: NSFont, color: NSColor = .black, indent: CGFloat = 0, before: CGFloat = 0, after: CGFloat
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        let out = NSMutableAttributedString(attributedString: inline(text, font: font, color: color, style: style))
        out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
        return out
    }

    private static func line(
        _ text: String, font: NSFont, color: NSColor, after: CGFloat, indent: CGFloat = 0, background: NSColor? = nil
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = after
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        if let background { attributes[.backgroundColor] = background }
        return NSAttributedString(string: text + "\n", attributes: attributes)
    }

    /// Inline Markdown (bold, italic, code) as fonts. A string that does not
    /// parse is kept as written.
    private static func inline(_ string: String, font: NSFont, color: NSColor, style: NSParagraphStyle) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: string, options: options) else {
            return NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var runFont = font
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.92, weight: .regular)
                } else {
                    var traits: NSFontDescriptor.SymbolicTraits = font.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                    if intent.contains(.emphasized) { traits.insert(.italic) }
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(traits), size: font.pointSize) ?? font
                }
            }
            out.append(NSAttributedString(
                string: text,
                attributes: [.font: runFont, .foregroundColor: color, .paragraphStyle: style]
            ))
        }
        return out
    }

    private static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size)
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }

    // MARK: - PDF

    /// The PDF bytes, paginated on US Letter, or nil if it could not be made.
    @MainActor
    static func render(markdown: String, title: String, subtitle: String) -> Data? {
        let content = attributedText(markdown: markdown, title: title, subtitle: subtitle)

        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: 100))
        view.isEditable = false
        view.drawsBackground = true
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        view.textStorage?.setAttributedString(content)
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        view.setFrameSize(NSSize(width: textWidth, height: ceil(layout.usedRect(for: container).height)))

        let data = NSMutableData()
        let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds, to: data, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), data.length > 0 else { return nil }
        return data as Data
    }
}
