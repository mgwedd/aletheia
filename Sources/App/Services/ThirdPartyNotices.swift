import Foundation

/// The third-party notices shown in Settings › Licenses. The text is the
/// repo-root `THIRD-PARTY-NOTICES.md`, copied into the app bundle as a
/// resource, so what is shown cannot differ from the file in the repository
/// (a unit test compares the two).
enum ThirdPartyNotices {
    static let resourceName = "THIRD-PARTY-NOTICES"
    static let resourceExtension = "md"

    private final class BundleToken {}

    /// The bundled notices, or nil when the resource is missing from the build.
    static func load(bundle: Bundle = Bundle(for: BundleToken.self)) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let unavailableMessage = "The license notices are missing from this build."

    /// One displayable piece of the document.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        /// A fenced block, shown verbatim (license texts).
        case code(String)
    }

    /// Splits the document into headings, paragraphs, list items and fenced
    /// blocks. Every non-blank line of the input lands in exactly one block.
    static func blocks(from text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            if code != nil {
                if line.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                code = []
            } else if let level = headingLevel(line) {
                flushParagraph()
                blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }

    private static func headingLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        return hashes
    }

    /// `text` as styled text with its web addresses made tappable.
    static func linkified(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let plain = String(result.characters)
        let pattern = #"https://[^\s)>`]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let whole = NSRange(plain.startIndex..., in: plain)
        for match in regex.matches(in: plain, range: whole) {
            guard var range = Range(match.range, in: plain) else { continue }
            // A sentence's closing punctuation is not part of the address.
            while let last = plain[range].last, ".,;:".contains(last) {
                range = range.lowerBound..<plain.index(before: range.upperBound)
            }
            guard let url = URL(string: String(plain[range])) else { continue }
            let from = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let to = result.characters.index(from, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound))
            result[from..<to].link = url
        }
        return result
    }
}
