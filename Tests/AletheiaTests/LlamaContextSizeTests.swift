import XCTest
@testable import Aletheia

final class LlamaContextSizeTests: XCTestCase {
    private let big = ContextBudget(tokens: 65_536)

    private func size(_ prompt: Int, reply: Int = 512, train: Int = 131_072, budget: ContextBudget? = nil) throws -> Int {
        try LlamaContextSize.contextTokens(
            promptTokens: prompt, replyTokens: reply, trainContext: train, budget: budget ?? big)
    }

    func testBucketsArePowersOfTwoFromTheFloor() {
        XCTAssertEqual(LlamaContextSize.bucket(for: 0), 8_192)
        XCTAssertEqual(LlamaContextSize.bucket(for: 8_192), 8_192)
        XCTAssertEqual(LlamaContextSize.bucket(for: 8_193), 16_384)
        XCTAssertEqual(LlamaContextSize.bucket(for: 30_000), 32_768)
        XCTAssertEqual(LlamaContextSize.bucket(for: 40_000), 65_536)
    }

    func testPromptPlusReplyPicksTheBucket() throws {
        XCTAssertEqual(try size(100), 8_192)
        XCTAssertEqual(try size(7_680, reply: 512), 8_192)
        XCTAssertEqual(try size(7_681, reply: 512), 16_384)
        XCTAssertEqual(try size(25_000), 32_768)
    }

    func testCappedAtBudgetAndTrainContext() throws {
        // 40K needs the 65,536 bucket, but a 49,152 budget caps the window there.
        XCTAssertEqual(try size(40_000, budget: ContextBudget(tokens: 49_152)), 49_152)
        XCTAssertEqual(try size(10_000, train: 12_000), 12_000)
        XCTAssertEqual(try size(10_000, train: 0), 16_384)  // 0 = unknown, no cap
    }

    func testOverTheCapThrowsInsteadOfTruncating() {
        let small = ContextBudget(tokens: 16_384)
        XCTAssertThrowsError(try size(16_000, budget: small)) {
            XCTAssertEqual($0 as? ContextBudgetError, ContextBudgetError(minutes: small.approximateMinutes))
        }
        // The train context can be the tighter cap.
        XCTAssertThrowsError(try size(9_000, train: 8_192)) { XCTAssertTrue($0 is ContextBudgetError) }
        XCTAssertNoThrow(try size(16_384 - 512, budget: small))
    }
}
