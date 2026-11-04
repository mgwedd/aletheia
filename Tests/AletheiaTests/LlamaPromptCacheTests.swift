import XCTest
@testable import Aletheia

/// How much of the previous request's cache the engine keeps. Keeping a
/// prefix must never change what the model sees, so every doubtful case reads
/// the whole prompt.
final class LlamaPromptCacheTests: XCTestCase {
    private func kept(_ cached: [Int32], _ prompt: [Int32], start: Int32 = 0, window: Int32 = 0) -> Int {
        LlamaPromptCache.reusableTokens(cached: cached, prompt: prompt, cacheStart: start, slidingWindow: window)
    }

    func testAFollowUpKeepsTheSharedPrefix() {
        XCTAssertEqual(kept([1, 2, 3, 4, 9, 9], [1, 2, 3, 4, 5, 6, 7]), 4)
    }

    func testAPromptThatExtendsTheCacheKeepsAllOfIt() {
        XCTAssertEqual(kept([1, 2, 3], [1, 2, 3, 4, 5]), 3)
    }

    /// The model has to read at least one token to give the next one's odds.
    func testTheSamePromptAgainLeavesOneTokenToRead() {
        XCTAssertEqual(kept([1, 2, 3, 4], [1, 2, 3, 4]), 3)
        XCTAssertEqual(kept([1, 2, 3, 4, 5], [1, 2, 3]), 2)
    }

    func testNothingSharedKeepsNothing() {
        XCTAssertEqual(kept([], [1, 2, 3]), 0)
        XCTAssertEqual(kept([7, 2, 3], [1, 2, 3]), 0)
        XCTAssertEqual(kept([1], [1]), 0)
    }

    /// Gemma 3's sliding-window layers drop old positions. The cache can be
    /// kept only if what those layers still hold covers the window before
    /// the first new token.
    func testASlidingWindowCacheIsKeptOnlyWhenItStillCoversTheWindow() {
        let cached = Array(Int32(0)..<Int32(2_000))
        let prompt = cached + [5_000, 5_001]
        XCTAssertEqual(kept(cached, prompt, start: 900, window: 1_024), 2_000, "positions 900…1999 cover the window before 2000")
        XCTAssertEqual(kept(cached, prompt, start: 1_200, window: 1_024), 0, "positions before 1200 are gone but the window needs them")
        XCTAssertEqual(kept(cached, prompt, start: 1, window: 0), 0, "a cache missing its start with no window is never kept")
    }

    func testAnUnknownCacheStartKeepsNothing() {
        XCTAssertEqual(kept([1, 2, 3], [1, 2, 3, 4], start: -1), 0)
    }
}
