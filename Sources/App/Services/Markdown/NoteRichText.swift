import Foundation
import AppKit

/// Converts between the Markdown a note is stored as and the styled text the
/// note editor shows, so a therapist sees a heading and a bold word instead of
/// `## ` and `**`. Storage never changes: notes stay Markdown files that the
/// local AI reads as text. Pure Foundation + AppKit (no SwiftUI), so the round
/// trip is unit-testable.
///
///     Markdown ──attributedString(fromMarkdown:)──▶ NSAttributedString ──▶ editor
///     Markdown ◀──────────markdown(from:)────────── NSAttributedString ◀── edits
///
/// Supported: paragraphs, `##` headings, `###` subheadings, `**bold**`,
/// `*italic*`, `- ` bullets and `1. ` numbered items. Anything else (code
/// fences, quotes, tables, HTML, links, images) is kept as a plain paragraph of
/// its literal text and written back unchanged, so no user text is ever lost.
///
/// Each paragraph carries its block type in `blockKey`; structure is never
/// inferred from fonts. Bold and italic, which the editor changes through font
/// traits, are read from the fonts on save. List markers ("•\t", "3.\t") are
/// real characters in the editing text, flagged with `markerKey`, and are
/// dropped on save; numbers are regenerated.
enum NoteRichText {
    /// The block type of the paragraph a character belongs to (a `Block` raw value).
    static let blockKey = NSAttributedString.Key("AletheiaNoteBlock")
    /// Set on the characters of a list marker, which are display-only.
    static let markerKey = NSAttributedString.Key("AletheiaNoteMarker")

    /// A line break inside one paragraph (Shift-Return in the editor, a single
    /// newline between two lines of a Markdown paragraph).
    static let lineBreak = "\u{2028}"

    enum Block: String, CaseIterable {
        case body, heading, subheading, bullet, numbered, literal

        var isList: Bool { self == .bullet || self == .numbered }
        var isHeading: Bool { self == .heading || self == .subheading }
    }

    // MARK: Fonts

    /// The type sizes an editor shows a note in, and the spacing around blocks.
    struct Fonts: Equatable {
        let body: NSFont
        let heading: NSFont
        let subheading: NSFont
        /// Extra leading between wrapped lines.
        let lineSpacing: CGFloat
        /// Space after a paragraph (what a blank line is in Markdown).
        let blockSpacing: CGFloat

        /// Interface type: My Notes. Matches `Theme.Typography.body`.
        static let sans = Fonts(
            body: NSFont.systemFont(ofSize: 14),
            heading: NSFont.systemFont(ofSize: 17, weight: .semibold),
            subheading: NSFont.systemFont(ofSize: 14, weight: .semibold),
            lineSpacing: 4,
            blockSpacing: 10
        )

        /// The drafted note's serif type. Matches `Theme.Typography.noteBody`
        /// and `noteHeading`.
        static let serif = Fonts(
            body: serifFont(size: 16, weight: .regular),
            heading: serifFont(size: 20, weight: .medium),
            subheading: serifFont(size: 16, weight: .semibold),
            lineSpacing: 6,
            blockSpacing: 12
        )

        private static func serifFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard
                let descriptor = base.fontDescriptor.withDesign(.serif),
                let font = NSFont(descriptor: descriptor, size: size)
            else { return base }
            return font
        }

        func baseFont(for block: Block) -> NSFont {
            switch block {
            case .heading: return heading
            case .subheading: return subheading
            case .body, .bullet, .numbered, .literal: return body
            }
        }

        /// The font for a block with bold / italic applied. Headings are already
        /// emphasized, so bold is ignored for them.
        func font(for block: Block, bold: Bool = false, italic: Bool = false) -> NSFont {
            let base = baseFont(for: block)
            let wantBold = bold && !block.isHeading
            guard wantBold || italic else { return base }

            var traits = base.fontDescriptor.symbolicTraits
            if wantBold { traits.insert(.bold) }
            if italic { traits.insert(.italic) }
            let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
            if let font = NSFont(descriptor: descriptor, size: base.pointSize) {
                let have = NoteRichText.traits(of: font)
                if (!wantBold || have.bold) && (!italic || have.italic) { return font }
            }

            // The descriptor route didn't produce the face (some design / weight
            // combinations); ask the font manager instead.
            var converted = base
            if wantBold { converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask) }
            if italic { converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask) }
            return converted
        }

        /// Paragraph layout for a block. `next` is the block that follows, so
        /// consecutive list items sit close together as one list.
        func paragraphStyle(for block: Block, next: Block?) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            if block.isList {
                // Marker, tab, text; wrapped lines hang under the text.
                style.firstLineHeadIndent = NoteRichText.listMarkerIndent
                style.headIndent = NoteRichText.listTextIndent
                style.tabStops = [NSTextTab(textAlignment: .left, location: NoteRichText.listTextIndent, options: [:])]
            }
            if block.isList && next == block {
                style.paragraphSpacing = 3
            } else if block.isHeading {
                style.paragraphSpacing = blockSpacing * 0.6
            } else {
                style.paragraphSpacing = blockSpacing
            }
            return style
        }

        /// Everything a character of `block` carries, except list-marker flags.
        func attributes(
            for block: Block,
            bold: Bool = false,
            italic: Bool = false,
            next: Block? = nil
        ) -> [NSAttributedString.Key: Any] {
            [
                .font: font(for: block, bold: bold, italic: italic),
                .foregroundColor: Theme.text.nsColor,
                .paragraphStyle: paragraphStyle(for: block, next: next),
                NoteRichText.blockKey: block.rawValue,
            ]
        }
    }

    /// Where a list marker starts and where the text (and wrapped lines) start.
    static let listMarkerIndent: CGFloat = 4
    static let listTextIndent: CGFloat = 26

    // MARK: Reading attributes

    static func traits(of font: NSFont) -> (bold: Bool, italic: Bool) {
        let symbolic = font.fontDescriptor.symbolicTraits
        return (symbolic.contains(.bold), symbolic.contains(.italic))
    }

    /// The block type of the paragraph that has the character at `index`
    /// (body when there is no character or no flag).
    static func blockKind(at index: Int, in string: NSAttributedString) -> Block {
        guard index >= 0, index < string.length,
              let raw = string.attribute(blockKey, at: index, effectiveRange: nil) as? String,
              let block = Block(rawValue: raw)
        else { return .body }
        return block
    }

    static func isTerminator(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029 || character == 0x85
    }

    /// The characters of `paragraph` before its line terminator.
    static func contentRange(ofParagraph paragraph: NSRange, in string: NSString) -> NSRange {
        var end = NSMaxRange(paragraph)
        while end > paragraph.location, isTerminator(string.character(at: end - 1)) { end -= 1 }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }

    /// The list marker at the start of `paragraph`, or an empty range there.
    static func markerRange(in string: NSAttributedString, paragraph: NSRange) -> NSRange {
        guard paragraph.length > 0, paragraph.location < string.length,
              string.attribute(markerKey, at: paragraph.location, effectiveRange: nil) != nil
        else { return NSRange(location: paragraph.location, length: 0) }
        var effective = NSRange(location: 0, length: 0)
        _ = string.attribute(markerKey, at: paragraph.location, longestEffectiveRange: &effective, in: paragraph)
        return effective
    }

    static func markerText(for block: Block, number: Int) -> String {
        block == .numbered ? "\(number).\t" : "\u{2022}\t"
    }

    static func markerString(for block: Block, number: Int = 1, fonts: Fonts) -> NSAttributedString {
        var attributes = fonts.attributes(for: block)
        attributes[markerKey] = "1"
        return NSAttributedString(string: markerText(for: block, number: number), attributes: attributes)
    }

    // MARK: Markdown → attributed string

    private struct ParsedBlock {
        var block: Block
        var text: String
    }

    private struct InlineRun {
        var text: String
        var bold: Bool
        var italic: Bool
    }

    static func attributedString(fromMarkdown markdown: String, font fonts: Fonts = .sans) -> NSAttributedString {
        let blocks = parse(markdown)
        let result = NSMutableAttributedString()
        var number = 0
        for (index, parsed) in blocks.enumerated() {
            if parsed.block == .numbered {
                number = (index > 0 && blocks[index - 1].block == .numbered) ? number + 1 : 1
            } else {
                number = 0
            }
            if parsed.block.isList {
                result.append(markerString(for: parsed.block, number: number, fonts: fonts))
            }
            result.append(styledContent(parsed.text, block: parsed.block, fonts: fonts))
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: fonts.attributes(for: parsed.block)))
            }
        }
        restyle(result, fonts: fonts)
        return result
    }

    private static func styledContent(_ text: String, block: Block, fonts: Fonts) -> NSAttributedString {
        let runs: [InlineRun] = block == .literal
            ? [InlineRun(text: text, bold: false, italic: false)]
            : inlineRuns(from: text)
        let result = NSMutableAttributedString()
        for run in runs where !run.text.isEmpty {
            result.append(NSAttributedString(
                string: run.text,
                attributes: fonts.attributes(for: block, bold: run.bold, italic: run.italic)
            ))
        }
        return result
    }

    /// Splits Markdown into blocks. Lossless for anything it doesn't model:
    /// such lines become `.literal` (or plain `.body`) text that is written back
    /// as it came.
    private static func parse(_ markdown: String) -> [ParsedBlock] {
        let unified = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = unified.components(separatedBy: "\n")

        var blocks: [ParsedBlock] = []
        var pending: [String] = []
        var pendingBlock: Block = .body

        func flush() {
            guard !pending.isEmpty else { return }
            blocks.append(ParsedBlock(block: pendingBlock, text: pending.joined(separator: lineBreak)))
            pending.removeAll()
            pendingBlock = .body
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]

            if isBlank(line) {
                flush()
                index += 1
                continue
            }

            // A quote, table or similar block runs to the next blank line.
            if !pending.isEmpty && pendingBlock == .literal {
                pending.append(line)
                index += 1
                continue
            }

            // Fenced code, including any blank lines inside it.
            if let fence = fenceMarker(of: line) {
                flush()
                var chunk = [line]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    chunk.append(next)
                    index += 1
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                }
                while chunk.count > 1, let last = chunk.last, isBlank(last) { chunk.removeLast() }
                blocks.append(ParsedBlock(block: .literal, text: chunk.joined(separator: lineBreak)))
                continue
            }

            if isThematicBreak(line) {
                flush()
                pendingBlock = .literal
                pending = [line]
                index += 1
                continue
            }

            if let heading = headingContent(of: line) {
                flush()
                blocks.append(ParsedBlock(block: heading.block, text: heading.text))
                index += 1
                continue
            }

            if let item = listItem(of: line) {
                flush()
                var parts = [item.text]
                while index + 1 < lines.count {
                    let next = lines[index + 1]
                    let leading = next.prefix(while: { $0 == " " }).count
                    guard !isBlank(next), leading >= 2 else { break }
                    parts.append(String(next.dropFirst(min(item.width, leading))))
                    index += 1
                }
                blocks.append(ParsedBlock(block: item.block, text: parts.joined(separator: lineBreak)))
                index += 1
                continue
            }

            if startsLiteral(line, insideParagraph: !pending.isEmpty) {
                flush()
                pendingBlock = .literal
                pending = [line]
                index += 1
                continue
            }

            pending.append(line)
            index += 1
        }
        flush()
        return blocks
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func fenceMarker(of line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    private static func headingContent(of line: String) -> (block: Block, text: String)? {
        let prefixes: [(String, Block)] = [("### ", .subheading), ("## ", .heading), ("# ", .heading)]
        for (prefix, block) in prefixes where line.hasPrefix(prefix) {
            let text = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return (block, text)
        }
        return nil
    }

    /// A bullet or numbered item: its block, its text, and how far a
    /// continuation line is indented.
    private static func listItem(of line: String) -> (block: Block, text: String, width: Int)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return (Block.bullet, String(line.dropFirst(2)), 2)
        }
        let digits = line.prefix(while: { $0.isASCII && $0.isNumber }).count
        if digits >= 1, digits <= 9, line.dropFirst(digits).hasPrefix(". ") {
            return (Block.numbered, String(line.dropFirst(digits + 2)), 3)
        }
        return nil
    }

    private static func startsLiteral(_ line: String, insideParagraph: Bool) -> Bool {
        if line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("<") { return true }
        if !insideParagraph && (line.hasPrefix("    ") || line.hasPrefix("\t")) { return true }
        if line.hasPrefix("[") && line.contains("]:") { return true }
        return false
    }

    /// Bold / italic runs of one line of text. If the line holds anything the
    /// editor can't show (links, code, escapes, strikethrough) or the parse
    /// would change its characters, the raw text is kept so it saves back
    /// as written.
    private static func inlineRuns(from text: String) -> [InlineRun] {
        let raw = [InlineRun(text: text, bold: false, italic: false)]
        guard text.contains("*") || text.contains("_") else { return raw }

        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: text, options: options) else { return raw }

        var runs: [InlineRun] = []
        var plain = ""
        for run in parsed.runs {
            if run.link != nil { return raw }
            let intent = run.inlinePresentationIntent ?? []
            if !intent.subtracting([.emphasized, .stronglyEmphasized]).isEmpty { return raw }
            let piece = String(parsed[run.range].characters)
            plain += piece
            runs.append(InlineRun(
                text: piece,
                bold: intent.contains(.stronglyEmphasized),
                italic: intent.contains(.emphasized)
            ))
        }
        let withoutMarks: (String) -> String = {
            $0.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "")
        }
        guard withoutMarks(plain) == withoutMarks(text) else { return raw }
        return runs
    }

    // MARK: Attributed string → Markdown

    static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        var chunks: [(block: Block, text: String)] = []

        var location = 0
        while location < string.length {
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let content = contentRange(ofParagraph: paragraph, in: string)
            let kind = blockKind(at: paragraph.location, in: attributed)

            var runs: [InlineRun] = []
            if content.length > 0 {
                attributed.enumerateAttributes(in: content, options: []) { attributes, range, _ in
                    if attributes[markerKey] != nil { return }
                    var bold = false
                    var italic = false
                    if let font = attributes[.font] as? NSFont {
                        let found = traits(of: font)
                        bold = found.bold
                        italic = found.italic
                    }
                    switch kind {
                    case .literal:
                        bold = false
                        italic = false
                    case .heading, .subheading:
                        bold = false
                    case .body, .bullet, .numbered:
                        break
                    }
                    let piece = string.substring(with: range)
                    if let last = runs.last, last.bold == bold, last.italic == italic {
                        runs[runs.count - 1].text += piece
                    } else {
                        runs.append(InlineRun(text: piece, bold: bold, italic: italic))
                    }
                }
            }

            var text = emit(runs)
            let continuation: String
            switch kind {
            case .bullet: continuation = "\n  "
            case .numbered: continuation = "\n   "
            default: continuation = "\n"
            }
            text = text.replacingOccurrences(of: lineBreak, with: continuation)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            chunks.append((kind, text))
        }

        var output = ""
        var number = 0
        for (index, chunk) in chunks.enumerated() {
            let previous: Block? = index > 0 ? chunks[index - 1].block : nil
            if chunk.block == .numbered {
                number = previous == .numbered ? number + 1 : 1
            }
            let line: String
            switch chunk.block {
            case .heading: line = "## " + chunk.text
            case .subheading: line = "### " + chunk.text
            case .bullet: line = "- " + chunk.text
            case .numbered: line = "\(number). " + chunk.text
            case .body, .literal: line = chunk.text
            }
            if index > 0 {
                output += (chunk.block.isList && previous == chunk.block) ? "\n" : "\n\n"
            }
            output += line
        }
        return output
    }

    /// Wraps bold / italic runs in markers. Spaces at the edges of a run go
    /// outside the markers (`**bold **word` becomes `**bold** word`), which
    /// Markdown requires for the markers to count.
    private static func emit(_ runs: [InlineRun]) -> String {
        var output = ""
        for run in runs {
            guard run.bold || run.italic else {
                output += run.text
                continue
            }
            let characters = Array(run.text)
            var start = 0
            var end = characters.count
            while start < end, characters[start].isWhitespace { start += 1 }
            while end > start, characters[end - 1].isWhitespace { end -= 1 }
            if start == end {
                output += run.text
                continue
            }
            let marker = run.bold && run.italic ? "***" : (run.bold ? "**" : "*")
            output += String(characters[0..<start])
            output += marker + String(characters[start..<end]) + marker
            output += String(characters[end...])
        }
        return output
    }

    // MARK: Editing support

    /// Sets each paragraph's layout from its block type (and its neighbour's),
    /// touching only paragraphs whose layout is out of date.
    static func restyle(_ string: NSMutableAttributedString, fonts: Fonts) {
        let text = string.string as NSString
        var paragraphs: [(range: NSRange, block: Block)] = []
        var location = 0
        while location < text.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append((range, blockKind(at: range.location, in: string)))
            location = NSMaxRange(range)
        }
        for (index, paragraph) in paragraphs.enumerated() {
            let next: Block? = index + 1 < paragraphs.count ? paragraphs[index + 1].block : nil
            let style = fonts.paragraphStyle(for: paragraph.block, next: next)
            let existing = string.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil) as? NSParagraphStyle
            if existing == nil || !style.isEqual(existing) {
                string.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            }
        }
    }

    /// Maps a selection through replacing `replaced` with `newLength` characters.
    private static func mapped(_ selection: NSRange, replacing replaced: NSRange, newLength: Int) -> NSRange {
        let delta = newLength - replaced.length
        func map(_ position: Int) -> Int {
            if replaced.length == 0 {
                return position >= replaced.location ? position + delta : position
            }
            if position >= NSMaxRange(replaced) { return position + delta }
            if position > replaced.location { return replaced.location + newLength }
            return position
        }
        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Brings an edited note back to a valid shape: every paragraph's characters
    /// share its block type, list paragraphs start with exactly one correct
    /// marker (renumbered), and other paragraphs have none. Returns `selection`
    /// moved to follow any markers added or removed.
    static func normalize(_ string: NSMutableAttributedString, fonts: Fonts, selection: NSRange) -> NSRange {
        var selection = selection
        var location = 0
        var previous: Block?
        var number = 0

        while location < string.length {
            let text = string.string as NSString
            var paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            let block = blockKind(at: paragraph.location, in: string)

            // Marker characters anywhere but the start (left by a merge) go.
            let marker = markerRange(in: string, paragraph: paragraph)
            var scan = NSMaxRange(marker)
            while scan < NSMaxRange(paragraph) {
                var effective = NSRange(location: 0, length: 0)
                let limit = NSRange(location: scan, length: NSMaxRange(paragraph) - scan)
                let value = string.attribute(markerKey, at: scan, longestEffectiveRange: &effective, in: limit)
                if value != nil {
                    string.deleteCharacters(in: effective)
                    selection = mapped(selection, replacing: effective, newLength: 0)
                    paragraph.length -= effective.length
                } else {
                    scan = NSMaxRange(effective)
                }
            }

            if block == .numbered {
                number = previous == .numbered ? number + 1 : 1
            } else {
                number = 0
            }

            let current = marker.length > 0 ? text.substring(with: marker) : ""
            if block.isList {
                let expected = markerText(for: block, number: max(number, 1))
                if current != expected {
                    let replacement = markerString(for: block, number: max(number, 1), fonts: fonts)
                    string.replaceCharacters(in: marker, with: replacement)
                    selection = mapped(selection, replacing: marker, newLength: replacement.length)
                }
            } else if marker.length > 0 {
                string.deleteCharacters(in: marker)
                selection = mapped(selection, replacing: marker, newLength: 0)
            }

            // The paragraph as it stands after the edits above.
            paragraph = (string.string as NSString).paragraphRange(for: NSRange(location: min(paragraph.location, string.length), length: 0))

            if paragraph.length > 0 {
                var effective = NSRange(location: 0, length: 0)
                _ = string.attribute(blockKey, at: paragraph.location, longestEffectiveRange: &effective, in: paragraph)
                if effective.location != paragraph.location || effective.length != paragraph.length {
                    string.addAttribute(blockKey, value: block.rawValue, range: paragraph)
                }
            }

            previous = block
            let next = NSMaxRange(paragraph)
            if next <= location { break }
            location = next
        }

        restyle(string, fonts: fonts)
        let length = string.length
        let start = min(selection.location, length)
        return NSRange(location: start, length: min(selection.length, length - start))
    }

    /// `source` (whole paragraphs) re-expressed as `target`: markers swapped,
    /// fonts re-based on the block's type with bold / italic kept, block flag set.
    static func converting(_ source: NSAttributedString, to target: Block, fonts: Fonts) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let text = source.string as NSString
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraph)
            let old = blockKind(at: paragraph.location, in: source)
            let content = contentRange(ofParagraph: paragraph, in: text)
            let terminator = NSRange(location: NSMaxRange(content), length: NSMaxRange(paragraph) - NSMaxRange(content))

            if target.isList {
                result.append(markerString(for: target, fonts: fonts))
            }
            if content.length > 0 {
                source.enumerateAttributes(in: content, options: []) { attributes, range, _ in
                    if attributes[markerKey] != nil { return }
                    var bold = false
                    var italic = false
                    if let font = attributes[.font] as? NSFont {
                        let found = traits(of: font)
                        bold = found.bold
                        italic = found.italic
                    }
                    if old.isHeading || old == .literal { bold = false }
                    if old == .literal { italic = false }
                    var updated = attributes
                    updated[.font] = fonts.font(for: target, bold: bold, italic: italic)
                    updated[blockKey] = target.rawValue
                    result.append(NSAttributedString(string: text.substring(with: range), attributes: updated))
                }
            }
            if terminator.length > 0 {
                result.append(NSAttributedString(
                    string: text.substring(with: terminator),
                    attributes: fonts.attributes(for: target)
                ))
            }
        }
        return result
    }
}
