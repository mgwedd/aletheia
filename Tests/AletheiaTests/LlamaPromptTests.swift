import XCTest
@testable import Aletheia
#if canImport(llama)

/// Template formatting needs no model: llama.cpp accepts a built-in template
/// name such as "chatml". Synthetic text only.
final class LlamaPromptTests: XCTestCase {
    func testAppliesNamedTemplateWithSystemAndGenerationPrompt() throws {
        let out = try XCTUnwrap(LlamaPrompt.applyTemplate("chatml", system: "Be brief.", prompt: "Hello"))
        XCTAssertEqual(out, "<|im_start|>system\nBe brief.<|im_end|>\n<|im_start|>user\nHello<|im_end|>\n<|im_start|>assistant\n")
    }

    func testGrowsBufferForLongPrompts() throws {
        let long = String(repeating: "word ", count: 5_000)
        let out = try XCTUnwrap(LlamaPrompt.applyTemplate("chatml", system: "", prompt: long))
        XCTAssertTrue(out.contains(long))
    }

    func testGemma4TemplateIsRenderedDirectly() {
        let out = LlamaPrompt.applyTemplate("{{- '<|turn>model\\n' -}}", system: "Be brief.", prompt: "Hello")
        XCTAssertEqual(out, "<bos><|turn>system\nBe brief.<turn|>\n<|turn>user\nHello<turn|>\n<|turn>model\n")
    }

    func testUnsupportedTemplateReturnsNilForRawFallback() {
        XCTAssertNil(LlamaPrompt.applyTemplate("not a real template", system: "", prompt: "Hi"))
        XCTAssertEqual(LlamaPrompt.rawPrompt(system: "S", prompt: "P"), "System: S\n\nP")
        XCTAssertEqual(LlamaPrompt.rawPrompt(system: " ", prompt: "P"), "P")
    }
}
#endif
