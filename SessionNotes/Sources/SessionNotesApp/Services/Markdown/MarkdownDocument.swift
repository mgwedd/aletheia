import Foundation

/// A single block of a parsed Markdown document. Deliberately small: it covers
/// the shapes a local model actually emits in a chat answer — prose, emphasis,
/// lists, quotes, headings, rules, and fenced code (including the ```mermaid
/// blocks the system prompt invites) — and nothing it doesn't.
///
/// Block boundaries are the parser's job; *inline* markup (bold, italic, inline
/// code, links) rides inside a block's text and is rendered with Apple's own
/// `AttributedString(markdown:)`, so this type stays a pure, platform-free value
/// that unit tests can exercise without SwiftUI.
enum MarkdownBlock: Equatable {
    /// `#`…`######` heading. `level` is clamped to 1...6.
    case heading(level: Int, text: String)
    /// A run of prose. Soft line breaks inside it are preserved.
    case paragraph(String)
    /// `-`, `*`, or `+` bullets. One string per item, marker stripped.
    case bulleted([String])
    /// `1.`, `2.`… items. One string per item, marker stripped.
    case numbered([String])
    /// `>` block quote. One string per quoted line, marker stripped.
    case quote([String])
    /// A fenced code block. `language` is the info string after the opening
    /// fence, lowercased and trimmed (nil when absent). `code` keeps the body
    /// verbatim, with no trailing newline.
    case code(language: String?, code: String)
    /// A thematic break (`---`, `***`, `___`).
    case rule
}

extension MarkdownBlock {
    /// True for a fenced block whose language marks it as a Mermaid diagram, so
    /// the renderer can present it as a diagram card rather than plain code.
    var isMermaid: Bool {
        if case let .code(language, _) = self { return language == "mermaid" }
        return false
    }
}

/// Turns a Markdown string into an ordered list of `MarkdownBlock`s.
///
/// Line-oriented and single-pass, with two properties that matter for a chat
/// UI that re-parses on every streamed token:
///
///  - **Cheap.** No regex engine in the hot path; each line is classified by a
///    handful of prefix checks.
///  - **Streaming-safe.** A partial document mid-stream is always valid input:
///    an unterminated code fence renders as a code block to the end rather than
///    swallowing the rest as prose, and a half-typed list still lists.
///
/// Pure Foundation, no SwiftUI, so the whole thing is unit-testable off-device.
enum MarkdownParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Split on newlines, keeping empty lines (they separate blocks). Handles
        // both LF and CRLF so pasted-in text behaves the same as generated text.
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code — consume until the closing fence or the end of input.
            if let fence = FenceMarker(trimmed) {
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if FenceMarker(candidate)?.isClosing(of: fence) == true {
                        index += 1 // step past the closing fence
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: fence.language, code: body.joined(separator: "\n")))
                continue
            }

            // Blank line — nothing to emit, just a separator.
            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Thematic break.
            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            // ATX heading.
            if let heading = heading(from: trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }

            // Block quote — gather consecutive `>` lines.
            if isQuote(trimmed) {
                var quoted: [String] = []
                while index < lines.count {
                    let q = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isQuote(q) else { break }
                    quoted.append(stripQuote(q))
                    index += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            // Bulleted list — gather consecutive bullet lines.
            if bulletItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count {
                    let b = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = bulletItem(from: b) else { break }
                    items.append(item)
                    index += 1
                }
                blocks.append(.bulleted(items))
                continue
            }

            // Numbered list — gather consecutive ordered items.
            if numberedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count {
                    let n = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let item = numberedItem(from: n) else { break }
                    items.append(item)
                    index += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // Paragraph — gather consecutive "plain" lines until a blank line or
            // the start of another block. Soft breaks are preserved with "\n".
            var paragraph: [String] = []
            while index < lines.count {
                let p = lines[index]
                let pt = p.trimmingCharacters(in: .whitespaces)
                if pt.isEmpty || FenceMarker(pt) != nil || isRule(pt) || heading(from: pt) != nil
                    || isQuote(pt) || bulletItem(from: pt) != nil || numberedItem(from: pt) != nil {
                    break
                }
                paragraph.append(pt)
                index += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }

        return blocks
    }

    // MARK: - Line classifiers

    /// An opening or closing code fence, and the language on an opening one.
    private struct FenceMarker {
        let character: Character   // ` or ~
        let count: Int
        let language: String?

        init?(_ trimmed: String) {
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            let run = trimmed.prefix { $0 == first }
            guard run.count >= 3 else { return nil }
            self.character = first
            self.count = run.count
            let info = trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespaces).lowercased()
            self.language = info.isEmpty ? nil : info
        }

        /// A fence closes a block when it uses the same character, is at least as
        /// long, and carries no info string.
        func isClosing(of open: FenceMarker) -> Bool {
            character == open.character && count >= open.count && language == nil
        }
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        let stripped = trimmed.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let rest = trimmed.dropFirst(hashes.count)
        // Require a space after the hashes, otherwise it's "#hashtag" prose.
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return .heading(level: hashes.count, text: text)
    }

    private static func isQuote(_ trimmed: String) -> Bool { trimmed == ">" || trimmed.hasPrefix("> ") }

    private static func stripQuote(_ trimmed: String) -> String {
        trimmed == ">" ? "" : String(trimmed.dropFirst(2))
    }

    private static func bulletItem(from trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedItem(from trimmed: String) -> String? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.first == "." || afterDigits.first == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
