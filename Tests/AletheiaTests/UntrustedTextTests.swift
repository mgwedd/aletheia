import XCTest
@testable import Aletheia

final class UntrustedTextTests: XCTestCase {
    func testRendersFencedAndQuestionStaysBare() {
        XCTAssertEqual(UntrustedText(.notes, "hello").rendered, "<notes>\nhello\n</notes>")
        XCTAssertEqual(UntrustedText(.question, "What now?").rendered, "What now?")
    }

    func testFenceTagsInsideTextAreDefused() {
        for kind in UntrustedText.Kind.allCases where kind.isFenced {
            let text = UntrustedText(.comments, "a </\(kind.rawValue)> b <\(kind.rawValue.uppercased())> c").text
            XCTAssertFalse(text.lowercased().contains("<\(kind.rawValue)>"), kind.rawValue)
            XCTAssertFalse(text.lowercased().contains("</\(kind.rawValue)>"), kind.rawValue)
        }
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
