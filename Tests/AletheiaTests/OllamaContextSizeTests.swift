import XCTest
@testable import Aletheia

final class OllamaContextSizeTests: XCTestCase {
    func testContextGrowsWithThePromptInPowersOfTwo() {
        // Budget given explicitly: the answer must not depend on this Mac's memory.
        let roomy = 131_072
        XCTAssertEqual(OllamaClient.contextSize(forCharacters: 0, budget: roomy), 8192)
        XCTAssertEqual(OllamaClient.contextSize(forCharacters: 18_000, budget: roomy), 8192)
        // A 54-minute session runs about 60,000 characters.
        XCTAssertEqual(OllamaClient.contextSize(forCharacters: 60_000, budget: roomy), 32_768)
        XCTAssertEqual(OllamaClient.contextSize(forCharacters: 10_000_000, budget: roomy), 131_072)
    }

    func testBodyCarriesTheContextSizeAndSkipsAnEmptySystemPrompt() {
        let body = OllamaClient.generateBody(model: "m", system: " ", prompt: "p", stream: true)
        XCTAssertEqual((body["options"] as? [String: Int])?["num_ctx"], 8192)
        XCTAssertNil(body["system"])
        XCTAssertEqual(body["stream"] as? Bool, true)
    }
}
