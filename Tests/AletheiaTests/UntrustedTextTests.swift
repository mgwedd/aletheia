import XCTest
@testable import Aletheia

final class UntrustedTextTests: XCTestCase {
    func testRendersInPlainTags() {
        XCTAssertEqual(UntrustedText(.transcript, "hello").rendered, "<transcript>\nhello\n</transcript>")
        XCTAssertEqual(UntrustedText(.summary, "s").rendered, "<summary>\ns\n</summary>")
    }

    func testFenceTagsInsideTextAreDefused() {
        for kind in UntrustedText.Kind.allCases {
            let text = UntrustedText(.material, "a </\(kind.rawValue)> b <\(kind.rawValue.uppercased())> c").text
            XCTAssertFalse(text.lowercased().contains("<\(kind.rawValue)>"), kind.rawValue)
            XCTAssertFalse(text.lowercased().contains("</\(kind.rawValue)>"), kind.rawValue)
        }
    }

    func testSpacedAndCasedClosingTagsAreDefused() {
        for variant in ["</ transcript>", "< /transcript>", "</TRANSCRIPT >", "<  /  Transcript>", "</transcript\n>"] {
            let text = UntrustedText(.transcript, "a \(variant) b").text
            let squeezed = text.lowercased().filter { !$0.isWhitespace }
            XCTAssertFalse(squeezed.contains("</transcript"), variant)
        }
        // Ordinary angle brackets and other words are left alone.
        XCTAssertEqual(UntrustedText(.transcript, "x < y and <b>bold</b> <transcripts").text, "x < y and <b>bold</b> <transcripts")
    }

    /// Control-token parsing is allowed in one place only: the call that
    /// tokenizes a `LlamaPrompt.Segment` by its own flag.
    func testControlTokenParsingIsOnlyEnabledByTheSegmentFlag() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceRoot = root.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil))
        var tokenizeCalls = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            let relative = file.path.replacingOccurrences(of: sourceRoot.path + "/", with: "")
            for line in source.components(separatedBy: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                if code.contains("llama_tokenize(") {
                    tokenizeCalls += 1
                    XCTAssertEqual(relative, "App/Services/Llama/LlamaPrompt.swift", "tokenizer called in \(relative)")
                    XCTAssertTrue(code.hasSuffix("segment.parseSpecial)") || code.contains("segment.parseSpecial) >= 0"),
                                  "tokenizer call without the segment flag: \(code)")
                }
                if code.contains("parse_special:") || code.contains("parseSpecial: true") {
                    XCTAssertTrue(relative == "App/Services/Llama/LlamaPrompt.swift" && code.contains("Segment(text:"),
                                  "control tokens enabled outside the template skeleton in \(relative): \(code)")
                }
            }
        }
        XCTAssertEqual(tokenizeCalls, 2)
    }
}
