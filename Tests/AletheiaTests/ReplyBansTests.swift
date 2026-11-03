import XCTest
@testable import Aletheia
#if canImport(llama)

/// Which tokens the engine never lets a reply contain. No model is loaded: the
/// vocabulary is stood in for by two predicates. Synthetic tokens only.
final class ReplyBansTests: XCTestCase {
    func testBansControlTokensThatDoNotEndTheTurn() {
        // Tokens 0-9: 3 and 6 are control tokens that open or close hidden spans.
        let bans = LlamaEngine.replyBans(
            tokenCount: 10,
            isControl: { [3, 6].contains($0) },
            endsTurn: { _ in false })
        XCTAssertEqual(bans, [3, 6])
    }

    func testKeepsControlTokensThatEndTheTurn() {
        // 2 is end of sequence, 5 an end-of-turn marker, 7 a reasoning marker.
        let bans = LlamaEngine.replyBans(
            tokenCount: 10,
            isControl: { [2, 5, 7].contains($0) },
            endsTurn: { [2, 5].contains($0) })
        XCTAssertEqual(bans, [7])
        XCTAssertFalse(bans.contains(2))
        XCTAssertFalse(bans.contains(5))
    }

    func testNeverBansOrdinaryTokens() {
        let none = LlamaEngine.replyBans(tokenCount: 50, isControl: { _ in false }, endsTurn: { _ in false })
        XCTAssertTrue(none.isEmpty)
        // A token that ends the turn but isn't marked control is not banned either.
        let onlyEnds = LlamaEngine.replyBans(tokenCount: 10, isControl: { _ in false }, endsTurn: { $0 == 4 })
        XCTAssertTrue(onlyEnds.isEmpty)
    }

    func testEveryControlTokenIsBannedWhenNoneEndTheTurn() {
        let bans = LlamaEngine.replyBans(tokenCount: 6, isControl: { _ in true }, endsTurn: { _ in false })
        XCTAssertEqual(bans, [0, 1, 2, 3, 4, 5])
    }

    func testEmptyVocabularyBansNothing() {
        XCTAssertTrue(LlamaEngine.replyBans(tokenCount: 0, isControl: { _ in true }, endsTurn: { _ in false }).isEmpty)
    }
}
#endif
